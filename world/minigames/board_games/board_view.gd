extends Node
## The desktop board view (dev 2026-10-26: "it would put the player in a new view with a 3D board
## and pieces"): Anon sits down at the game table (board_table.gd) and the camera moves over the
## board. Click a piece, then a square (or drag it there); right-drag looks around, the wheel
## zooms. The game card (top left) shows whose move it is and the moves so far, starts a game
## (or asks a pony to play), takes up one left unfinished with her, resigns, sets the game aside
## to finish later (board_adjourned.gd) and leaves. The talk card (top right) is the conversation:
## what she says appears there word by word as she speaks, in her coat colour, with what he
## says and a line to type in; the usual caption and the words over her head step aside while
## the view is open (dev 2026-10-26: subtitles ran off the bottom of the screen over the bar).
## Escape leaves; the game waits while he stays near. The view is the desktop activity owner,
## so menus close it before they open.
const MODELS := preload("res://world/minigames/board_games/board_models.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const READABLE := preload("res://world/ui/readable_text_theme.gd")
const OVERHEAD := preload("res://world/ai/overhead_dialogue.gd")
const ACCENT := Color("c9a6ff")
const PROMOTIONS := [["Queen", 5], ["Rook", 4], ["Bishop", 3], ["Knight", 2]]
## Camera orbit around the board: degrees above the board, metres from it, turn either side.
const PITCH := Vector2(22.0, 86.0)
const DISTANCE := Vector2(0.42, 2.2)
## The camera frames the board and her face together (dev 2026-10-29: "wider, more angle of view
## ... it's hard to see the pony face"): a wider lens, tilted so the near edge of the board sits at
## the bottom and her face (headroom above it) at the top; zoomed too close for both, the board
## wins. Before she sits, a seated pony's face above her cushion stands in.
const FOV := 62.0
const START_DISTANCE := 0.95
const HEADROOM := 0.12
const SEATED_FACE := 0.85
## How fast the framing follows her face, so her breathing and nods do not sway the view.
const FACE_EASE := 3.0
const YAW_LIMIT := 75.0
## Both cards: their width as a share of the screen, within these pixels, and the margin.
const CARD_SHARE := 0.27
const CARD_WIDTH := Vector2(260.0, 380.0)
const MARGIN := 24.0
## Lines the talk card keeps (older ones scroll up and fade).
const TALK_LINES := 14
const WORDS_SIZE := 17
var table: Node3D
var inventory: Node
var camera: Camera3D
var _previous_camera: Camera3D
var _body: Node
var _lock_before := false
var _mouse_before := Input.MOUSE_MODE_CAPTURED
var _pitch := 35.0
var _distance := START_DISTANCE
var _yaw := 0.0
var _face := Vector3.INF
var _orbiting := false
var _selected := -1
var _pressed_on := -1
var _hover := -1
var _promotion := {}
var _marks: Node3D
var _layer: CanvasLayer
var _game_card: PanelContainer
var _title: Label
var _status: Label
var _moves: Label
var _setup: VBoxContainer
var _chat: LineEdit
var _resign: Button
var _aside: Button
var _promote_box: HBoxContainer
var _talk_card: PanelContainer
var _talk_scroll: ScrollContainer
var _talk_log: VBoxContainer
var _talk_note: Label
## {"actor": instance id (0 for Anon), "text", "words": Label, "done"} oldest first.
var _talk: Array[Dictionary] = []
var _follow_frames := 0
var _time := 0.0
var _director: Node
var _voice_hud: Node
## The cushion he sat on for this view: getting up from it (the get-up key, a fall, her magic)
## leaves the board. Not seated at all, his body steps out of the board camera's way instead.
var _seat: Node3D
var _hid_body := false
var _game_choice := "chess"
var _closing := false
var _hidden_hud: Array[CanvasLayer] = []
var _hud_was_hidden := false

## True when the view took over (the table frees it otherwise).
func open(p_table: Node3D, ui: Node) -> bool:
	table = p_table
	inventory = ui
	if not DESKTOP_OWNER.claim(inventory, self): return false
	_body = inventory.get("player_body") as Node
	_previous_camera = inventory.get("camera") as Camera3D
	# Sit down on Anon's cushion first: a locked body cannot sit.
	if is_instance_valid(_body) and _body.has_method("sit_on") and not is_instance_valid(_body.get("seat")) and is_instance_valid(table.get("player_seat")):
		_body.call("sit_on", table.get("player_seat"))
	var sat: Variant = _body.get("seat") if is_instance_valid(_body) else null
	_seat = sat as Node3D if is_instance_valid(sat) else null
	# Standing (the cushion was out of reach, say from her side of the table), the board camera
	# would look out from inside him.
	if _seat == null: _show_body(false)
	_lock_before = bool(_body.get("controls_locked")) if is_instance_valid(_body) else false
	if is_instance_valid(_body): _body.set("controls_locked", true)
	_mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	camera = Camera3D.new(); camera.name = "BoardCamera"
	camera.fov = FOV; camera.near = 0.02
	if is_instance_valid(_previous_camera):
		camera.environment = _previous_camera.environment
		camera.attributes = _previous_camera.attributes
		camera.cull_mask = _previous_camera.cull_mask
	camera.top_level = true
	add_child(camera)
	_place_camera()
	camera.make_current()
	_marks = Node3D.new(); _marks.name = "BoardMarks"
	table.get("board").add_child(_marks)
	_game_choice = str(table.get("game"))
	_build_hud()
	_show_game_hud(false)
	_listen(true)
	table.connect("changed", _refresh)
	get_viewport().size_changed.connect(_fit_layout)
	_fit_layout()
	_refresh()
	return true

func close() -> void:
	if _closing: return
	_closing = true
	_listen(false)
	if is_instance_valid(table) and table.is_connected("changed", _refresh): table.disconnect("changed", _refresh)
	_lift(_selected, false)
	if is_instance_valid(_marks): _marks.queue_free()
	if is_instance_valid(_previous_camera) and is_instance_valid(camera) and camera.current: _previous_camera.make_current()
	_show_game_hud(true)
	_show_body(true)
	if is_instance_valid(_body): _body.set("controls_locked", _lock_before)
	Input.mouse_mode = _mouse_before if _mouse_before != Input.MOUSE_MODE_VISIBLE else Input.MOUSE_MODE_CAPTURED
	if is_instance_valid(inventory): DESKTOP_OWNER.release(inventory, self)
	if is_instance_valid(table): table.call("view_closed", self)
	queue_free()

## Menus (pause, inventory, map) close the view before taking the mouse.
func cancel_desktop_activity() -> void:
	close()

func _exit_tree() -> void:
	if not _closing: close()

## The minimap and the hotbar step aside while the board fills the view (the voice indicator
## stays: he can still talk to her).
func _show_game_hud(show: bool) -> void:
	if not show:
		_hud_was_hidden = bool(inventory.get("hud_hidden"))
		inventory.set("hud_hidden", true)
		for node: Node in get_tree().root.find_children("*", "CanvasLayer", true, false):
			var script: Script = node.get_script() as Script
			if script != null and script.resource_path.ends_with("world_map_hud.gd") and (node as CanvasLayer).visible:
				(node as CanvasLayer).visible = false
				_hidden_hud.append(node as CanvasLayer)
		return
	if is_instance_valid(inventory): inventory.set("hud_hidden", _hud_was_hidden)
	for layer: CanvasLayer in _hidden_hud:
		if is_instance_valid(layer): layer.visible = true
	_hidden_hud.clear()

## His desktop body (desktop_anon.gd) out of the view while he plays standing; back when he leaves.
func _show_body(show: bool) -> void:
	if show and not _hid_body: return
	var presentation: Variant = inventory.get("desktop_presentation") if is_instance_valid(inventory) else null
	if not (presentation is Node and is_instance_valid(presentation) and (presentation as Node).has_method("set_enabled")): return
	_hid_body = not show
	(presentation as Node).call("set_enabled", show)

## Up off the cushion he sat on for the game.
func _got_up() -> bool:
	if _seat == null: return false
	var now: Variant = _body.get("seat") if is_instance_valid(_body) else null
	return not is_instance_valid(_seat) or not is_instance_valid(now) or now != _seat

func _session() -> Node:
	var live: Variant = table.get("session")
	return live as Node if is_instance_valid(live) else null

# ------------------------------------------------------------------ camera

func _place_camera() -> void:
	var target: Vector3 = (table.get("board") as Node3D).global_position + Vector3.UP * 0.01
	var toward_player := _toward_player()
	var pitch := deg_to_rad(_pitch)
	camera.global_position = target + toward_player * cos(pitch) * _distance + Vector3.UP * sin(pitch) * _distance
	if not _face.is_finite(): _face = _face_point(toward_player)
	# The lowest of the board's corners: orbiting at a slant, the nearest one dips below the edge.
	var board: Node3D = table.get("board")
	var half := MODELS.half_size()
	var low := INF
	for corner: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		low = minf(low, _elevation(board.global_transform * Vector3(corner.x * half, 0.01, corner.y * half), -toward_player))
	var high := _elevation(_face + Vector3.UP * HEADROOM, -toward_player)
	var aim := clampf(minf((low + high) * 0.5, low + deg_to_rad(FOV * 0.5 - 3.0)), deg_to_rad(-88.0), deg_to_rad(60.0))
	camera.look_at(camera.global_position - toward_player * cos(aim) + Vector3.UP * sin(aim), Vector3.UP)

## Flat, from the board towards Anon's side, turned by the orbit.
func _toward_player() -> Vector3:
	var toward: Vector3 = table.global_basis.z
	toward.y = 0.0
	return toward.normalized().rotated(Vector3.UP, deg_to_rad(_yaw))

## Degrees (radians) above the camera's level a point is, seen looking along `forward` (flat).
func _elevation(point: Vector3, forward: Vector3) -> float:
	var offset := point - camera.global_position
	return atan2(offset.y, offset.dot(forward))

## Her face once she is seated at the board, otherwise where it will be on her cushion.
func _face_point(toward_player: Vector3) -> Vector3:
	var opponent: Dictionary = table.get("opponent")
	var actor: Variant = opponent.get("actor")
	if str(opponent.get("state", "")) == "seated" and is_instance_valid(actor) and (actor as Node).has_method("listen_point"):
		var nose: Variant = (actor as Node).call("listen_point")
		if nose is Vector3 and (nose as Vector3).is_finite(): return nose
	var seat: Variant = table.get("pony_seat")
	var board_at: Vector3 = (table.get("board") as Node3D).global_position
	var floor_at: Vector3 = (seat as Node3D).global_position if is_instance_valid(seat) else board_at - toward_player * 0.8
	return floor_at + Vector3.UP * SEATED_FACE

# ------------------------------------------------------------------ input

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	var key := (event as InputEventKey).physical_keycode
	if _chat.has_focus():
		if key == KEY_ESCAPE: _chat.release_focus(); get_viewport().set_input_as_handled()
		return
	if key == KEY_ESCAPE:
		if not _promotion.is_empty(): _cancel_promotion()
		else: close()
		get_viewport().set_input_as_handled()
	elif key == KEY_ENTER or key == KEY_KP_ENTER:
		_chat.grab_focus()
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		match button.button_index:
			MOUSE_BUTTON_RIGHT:
				_orbiting = button.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if button.pressed: _distance = clampf(_distance * 0.9, DISTANCE.x, DISTANCE.y); _place_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if button.pressed: _distance = clampf(_distance / 0.9, DISTANCE.x, DISTANCE.y); _place_camera()
			MOUSE_BUTTON_LEFT:
				if _chat.has_focus(): _chat.release_focus()
				var sq := _square_under(button.position)
				if button.pressed: _press(sq)
				else: _release(sq)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _orbiting:
			_yaw = clampf(_yaw - motion.relative.x * 0.25, -YAW_LIMIT, YAW_LIMIT)
			_pitch = clampf(_pitch + motion.relative.y * 0.2, PITCH.x, PITCH.y)
			_place_camera()
		var sq := _square_under(motion.position)
		if sq != _hover:
			_hover = sq
			_marks_refresh()

## The square under the mouse: a piece first (its whole height), else the board itself.
func _square_under(screen: Vector2) -> int:
	if not is_instance_valid(camera): return -1
	var origin := camera.project_ray_origin(screen)
	var direction := camera.project_ray_normal(screen)
	var board: Node3D = table.get("board")
	var best := -1
	var nearest := INF
	var flat := Vector2(direction.x, direction.z).length_squared()
	var nodes: Dictionary = table.get("_piece_nodes")
	for sq: int in nodes:
		var node: Node3D = nodes[sq] as Node3D
		if not is_instance_valid(node) or flat < 1e-6: continue
		var axis := node.global_position
		var t := -((origin.x - axis.x) * direction.x + (origin.z - axis.z) * direction.z) / flat
		if t <= 0.0 or t >= nearest: continue
		var at := origin + direction * t
		var height := float(node.get_meta("height", MODELS.SQUARE)) + 0.008
		if Vector2(at.x - axis.x, at.z - axis.z).length() < MODELS.piece_radius() and at.y > axis.y - 0.005 and at.y < axis.y + height:
			nearest = t; best = sq
	if best >= 0: return best
	var plane := Plane(board.global_basis.y.normalized(), board.global_position)
	var hit: Variant = plane.intersects_ray(origin, direction)
	return MODELS.square_at(board.to_local(hit)) if hit is Vector3 else -1

func _press(sq: int) -> void:
	_pressed_on = -1
	var session := _session()
	if session == null or not _promotion.is_empty() or sq < 0: return
	# Its own square is a target only for a checkers king's ring of jumps back to where it began:
	# clicking the picked-up piece again makes that move.
	if _selected >= 0 and session.call("targets_from", _selected).has(sq):
		_try_move(_selected, sq)
		return
	if not (session.call("targets_from", sq) as PackedInt32Array).is_empty():
		_select(sq)
		_pressed_on = sq
	else: _select(-1)

## Releasing over another square after pressing on a piece: a drag.
func _release(sq: int) -> void:
	if _pressed_on < 0 or sq < 0 or sq == _pressed_on: _pressed_on = -1; return
	var from := _pressed_on
	_pressed_on = -1
	var session := _session()
	if session != null and session.call("targets_from", from).has(sq): _try_move(from, sq)

func _try_move(from: int, to: int) -> void:
	var session := _session()
	if session == null: return
	if bool(session.call("promotes", from, to)):
		_promotion = {"from": from, "to": to}
		_promote_box.show()
		return
	_lift(_selected, false)
	_selected = -1
	session.call("player_move", from, to, 0)
	_marks_refresh()

func _choose_promotion(kind: int) -> void:
	var session := _session()
	if session != null and not _promotion.is_empty(): session.call("player_move", int(_promotion.from), int(_promotion.to), kind)
	_cancel_promotion()
	_lift(_selected, false)
	_selected = -1
	_marks_refresh()

func _cancel_promotion() -> void:
	_promotion = {}
	if is_instance_valid(_promote_box): _promote_box.hide()

func _select(sq: int) -> void:
	_lift(_selected, false)
	_selected = sq
	_lift(_selected, true)
	_marks_refresh()

## A picked-up piece rises a little off its square.
func _lift(sq: int, up: bool) -> void:
	if sq < 0 or not is_instance_valid(table): return
	var node: Node3D = table.call("piece_node", sq)
	if node != null: node.position.y = 0.012 if up else 0.0

# ------------------------------------------------------------------ marks on the board

func _marks_refresh() -> void:
	if not is_instance_valid(_marks): return
	for child: Node in _marks.get_children(): child.queue_free()
	var session := _session()
	if session == null: return
	var last: Variant = session.get("last_move")
	if last != null and not bool(session.get("animating")):
		var rules: RefCounted = session.get("rules")
		_square_mark(rules.from_sq(last), Color(0.95, 0.8, 0.3, 0.32))
		_square_mark(rules.to_sq(last), Color(0.95, 0.8, 0.3, 0.42))
	if _hover >= 0 and _hover != _selected: _square_mark(_hover, Color(1, 1, 1, 0.14))
	if _selected >= 0:
		_square_mark(_selected, Color(ACCENT, 0.5))
		for to: int in session.call("targets_from", _selected):
			var dot := MeshInstance3D.new()
			var disc := CylinderMesh.new(); disc.top_radius = MODELS.SQUARE * 0.17; disc.bottom_radius = disc.top_radius; disc.height = 0.002
			dot.mesh = disc
			dot.material_override = _flat_material(Color(ACCENT, 0.75))
			dot.position = MODELS.square_position(to) + Vector3.UP * 0.002
			_marks.add_child(dot)
	var rules: RefCounted = session.get("rules")
	if str(session.get("game")) == "chess" and session.get("result").is_empty() and bool(rules.in_check()):
		_square_mark(rules.kings[0 if int(rules.side) == 1 else 1], Color(0.95, 0.2, 0.2, 0.5))

func _square_mark(sq: int, color: Color) -> void:
	var quad := MeshInstance3D.new()
	var mesh := PlaneMesh.new(); mesh.size = Vector2.ONE * MODELS.SQUARE
	quad.mesh = mesh
	quad.material_override = _flat_material(color)
	quad.position = MODELS.square_position(sq) + Vector3.UP * 0.0012
	_marks.add_child(quad)

func _flat_material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = color
	mat.no_depth_test = false
	return mat

# ------------------------------------------------------------------ panel

func _build_hud() -> void:
	_layer = CanvasLayer.new(); _layer.name = "BoardHud"; _layer.layer = 6
	add_child(_layer)
	var root := Control.new(); root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE; root.theme = READABLE.make()
	_layer.add_child(root)
	# The game card, top left: the game, whose move, the moves, starting one, resigning, leaving.
	_game_card = _card_at(root, false)
	var column := VBoxContainer.new(); column.add_theme_constant_override("separation", 8)
	_game_card.add_child(column)
	_title = Label.new(); _title.add_theme_font_size_override("font_size", 24); _title.add_theme_color_override("font_color", ACCENT)
	_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_title)
	_status = Label.new(); _status.add_theme_font_size_override("font_size", 20); _status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_status)
	_moves = Label.new(); _moves.add_theme_font_size_override("font_size", 15); _moves.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_moves.modulate = Color(1, 1, 1, 0.8)
	column.add_child(_moves)
	_setup = VBoxContainer.new(); _setup.add_theme_constant_override("separation", 6)
	column.add_child(_setup)
	_promote_box = HBoxContainer.new(); _promote_box.add_theme_constant_override("separation", 6)
	var promote_label := Label.new(); promote_label.text = "Promote to:"
	_promote_box.add_child(promote_label)
	for row: Array in PROMOTIONS:
		var b := Button.new(); b.text = str(row[0]); b.pressed.connect(_choose_promotion.bind(int(row[1])))
		_promote_box.add_child(b)
	_promote_box.hide()
	column.add_child(_promote_box)
	column.add_child(_rule())
	var actions := HBoxContainer.new(); actions.add_theme_constant_override("separation", 8)
	column.add_child(actions)
	_resign = _button(actions, "Resign", _on_resign)
	_resign.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_aside = _button(actions, "Finish later", _on_set_aside)
	_aside.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button(actions, "Leave (Esc)", close).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var help := Label.new()
	help.text = "Click a piece, then a square · right-drag to look around · wheel to zoom"
	help.add_theme_font_size_override("font_size", 13); help.modulate = Color(1, 1, 1, 0.55)
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(help)
	# The talk card, top right: the conversation, newest at the bottom, and a line to type in.
	_talk_card = _card_at(root, true)
	var talk := VBoxContainer.new(); talk.add_theme_constant_override("separation", 10)
	_talk_card.add_child(talk)
	var heading := Label.new(); heading.text = "TABLE TALK"
	heading.add_theme_font_size_override("font_size", 12); heading.add_theme_color_override("font_color", Color(ACCENT, 0.75))
	talk.add_child(heading)
	_talk_scroll = ScrollContainer.new()
	_talk_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_talk_scroll.hide()
	talk.add_child(_talk_scroll)
	_talk_log = VBoxContainer.new(); _talk_log.add_theme_constant_override("separation", 12)
	_talk_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL; _talk_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_talk_scroll.add_child(_talk_log)
	_talk_note = Label.new(); _talk_note.add_theme_font_size_override("font_size", 15); _talk_note.modulate = Color(1, 1, 1, 0.6)
	_talk_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_talk_note.hide()
	talk.add_child(_talk_note)
	_chat = LineEdit.new(); _chat.placeholder_text = "Say something… (Enter)"
	_chat.add_theme_font_size_override("font_size", 17)
	_chat.add_theme_stylebox_override("normal", _field(false)); _chat.add_theme_stylebox_override("focus", _field(true))
	_chat.text_submitted.connect(_say)
	talk.add_child(_chat)

## A card hugging the top-left or top-right corner; it grows down with what it holds.
func _card_at(root: Control, right: bool) -> PanelContainer:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", _card())
	card.set_anchors_preset(Control.PRESET_TOP_RIGHT if right else Control.PRESET_TOP_LEFT)
	card.grow_horizontal = Control.GROW_DIRECTION_BEGIN if right else Control.GROW_DIRECTION_END
	card.grow_vertical = Control.GROW_DIRECTION_END
	root.add_child(card)
	return card

## Both cards share the screen's sides; the conversation scrolls once it would pass half of it.
func _fit_layout() -> void:
	if _closing or not is_instance_valid(_game_card): return
	var view := get_viewport().get_visible_rect().size
	var width := clampf(view.x * CARD_SHARE, CARD_WIDTH.x, CARD_WIDTH.y)
	_game_card.offset_left = MARGIN; _game_card.offset_right = MARGIN + width
	_game_card.offset_top = MARGIN; _game_card.offset_bottom = MARGIN
	_talk_card.offset_left = -MARGIN - width; _talk_card.offset_right = -MARGIN
	_talk_card.offset_top = MARGIN; _talk_card.offset_bottom = MARGIN
	_follow_frames = 4

func _talk_height() -> float:
	return clampf(get_viewport().get_visible_rect().size.y * 0.55 - 120.0, 90.0, 460.0)

func _card() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.11, 0.9); style.border_color = Color(ACCENT, 0.55)
	style.set_border_width_all(2); style.set_corner_radius_all(14); style.set_content_margin_all(16)
	return style

func _field(focused: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.07 if focused else 0.04)
	style.border_color = Color(ACCENT, 0.8 if focused else 0.3)
	style.set_border_width_all(1); style.set_corner_radius_all(9)
	style.content_margin_left = 12; style.content_margin_right = 12; style.content_margin_top = 8; style.content_margin_bottom = 8
	return style

func _rule() -> HSeparator:
	var line := HSeparator.new()
	var style := StyleBoxLine.new(); style.color = Color(ACCENT, 0.2); style.thickness = 1
	line.add_theme_stylebox_override("separator", style)
	return line

func _refresh() -> void:
	if _closing or not is_instance_valid(table): return
	var session := _session()
	var opponent: Dictionary = table.get("opponent")
	var game_name := str(session.get("game")) if session != null else _game_choice
	var who := str(session.get("opponent").get("name", "")) if session != null else str(opponent.get("name", ""))
	_title.text = game_name.capitalize() + (" with " + who if who != "" else "")
	_status.text = str(table.call("status_text"))
	_moves.text = str(session.call("moves_text")) if session != null else ""
	_moves.visible = _moves.text != ""
	var playing: bool = session != null and not bool(session.call("is_over"))
	_resign.visible = playing
	_aside.visible = playing
	if not playing: _cancel_promotion()
	if session == null or not playing:
		_lift(_selected, false); _selected = -1
	_rebuild_setup(session, playing)
	_marks_refresh()

## Starting a game: with the pony at the table, or asking one; after a game, another.
func _rebuild_setup(session: Node, playing: bool) -> void:
	for child: Node in _setup.get_children(): child.queue_free()
	if playing: return
	var opponent: Dictionary = table.get("opponent")
	var invite: Dictionary = table.get("invite")
	if not invite.is_empty(): return
	if not opponent.is_empty():
		if str(opponent.get("state", "")) != "seated": return
		for game_name: String in ["chess", "checkers"]:
			if bool(table.call("has_unfinished", game_name)):
				_button(_setup, "Continue %s with %s" % [game_name, opponent.name], _start.bind(game_name))
				_button(_setup, "New %s game with %s" % [game_name, opponent.name], _start.bind(game_name, true))
				continue
			var label := ("Play again" if session != null and str(session.get("game")) == game_name else "Play %s" % game_name)
			_button(_setup, label + " with " + str(opponent.name), _start.bind(game_name))
		return
	var choice := HBoxContainer.new(); choice.add_theme_constant_override("separation", 6)
	_setup.add_child(choice)
	for game_name: String in ["chess", "checkers"]:
		var b := _button(choice, game_name.capitalize(), _pick_game.bind(game_name))
		b.toggle_mode = true
		b.button_pressed = _game_choice == game_name
	var who: Array = table.call("candidates")
	if who.is_empty():
		var none := Label.new(); none.text = "Nopony nearby to play with."; none.modulate = Color(1, 1, 1, 0.75)
		_setup.add_child(none)
		return
	var ask_label := Label.new(); ask_label.text = "Ask somepony to play:"
	_setup.add_child(ask_label)
	for row: Dictionary in who.slice(0, 6):
		var unfinished: bool = table.call("has_unfinished", _game_choice, str(row.id))
		_button(_setup, str(row.name) + (" (unfinished game)" if unfinished else ""), _ask.bind(row.actor))

func _start(game_name: String, fresh := false) -> void:
	table.call("start_game", game_name, fresh)

func _pick_game(game_name: String) -> void:
	_game_choice = game_name
	if _session() == null and (table.get("opponent") as Dictionary).is_empty():
		table.call("show_position", _game_choice, table.call("_start_position", _game_choice))
	_refresh()

func _ask(actor: Node3D) -> void:
	var why := str(table.call("ask", actor, _game_choice))
	if why != "": table.set("notice", why)
	_refresh()

func _button(parent: Node, text: String, action: Callable) -> Button:
	var b := Button.new(); b.text = text; b.custom_minimum_size.y = 36
	b.pressed.connect(action)
	parent.add_child(b)
	return b

func _on_resign() -> void:
	var session := _session()
	if session != null: session.call("resign", int(session.get("player_side")))

func _on_set_aside() -> void:
	var session := _session()
	if session != null: session.call("set_aside")

## Typed words go to whoever he is facing across the table, like the chat box does; the talk
## card shows them once the director has heard them (_on_heard), spoken or typed.
func _say(text: String) -> void:
	_chat.text = ""
	_chat.release_focus()
	if text.strip_edges() != "" and is_instance_valid(_director) and _director.has_method("handle_text"): _director.handle_text(text)

# ------------------------------------------------------------------ the conversation

## The words come here instead of the caption while the view is open (voice_hud.gd words_owner).
func _listen(on: bool) -> void:
	if on:
		_director = get_tree().get_first_node_in_group("conversation_director")
		_voice_hud = _director.get("hud") as Node if is_instance_valid(_director) else null
		if is_instance_valid(_director) and _director.has_signal("transcript"): _director.connect("transcript", _on_heard)
		if is_instance_valid(_voice_hud) and _voice_hud.has_signal("words_shown"):
			_voice_hud.connect("words_shown", _on_words)
			_voice_hud.set("words_owner", self)
		return
	if is_instance_valid(_director) and _director.is_connected("transcript", _on_heard): _director.disconnect("transcript", _on_heard)
	if is_instance_valid(_voice_hud) and _voice_hud.has_signal("words_shown"):
		if _voice_hud.is_connected("words_shown", _on_words): _voice_hud.disconnect("words_shown", _on_words)
		if _voice_hud.get("words_owner") == self: _voice_hud.set("words_owner", null)

func _on_heard(text: String) -> void:
	if text.strip_edges() == "": return
	var row := _add_talk(0, "You", ACCENT, text, true)
	(row.words as Label).visible_characters = -1
	row.done = true

## A line as she says it: `shown` characters of `text` so far (all of it once she is done).
func _on_words(actor: Node, speaker: String, text: String, shown: int) -> void:
	if text.strip_edges() == "" or not _subtitles_on(): return
	var id := actor.get_instance_id() if is_instance_valid(actor) else -1
	var row: Dictionary = {}
	# Her line so far, or (the end of a line already shown whole, as without a voice) the same one.
	for i in range(_talk.size() - 1, maxi(-1, _talk.size() - 5), -1):
		if int(_talk[i].actor) == id and str(_talk[i].text) == text and (not bool(_talk[i].done) or shown >= text.length()): row = _talk[i]; break
	if row.is_empty(): row = _add_talk(id, speaker, _speaker_color(actor), text, false)
	var words: Label = row.words
	if shown >= text.length():
		words.visible_characters = -1
		row.done = true
	elif words.visible_characters >= 0: words.visible_characters = maxi(words.visible_characters, shown)
	_follow_frames = 4

## One line in the talk card: the speaker's name small in her colour, the words beneath (his on
## the right). Only the words said so far are laid out, so a line taller than the card keeps
## its newest words in view as the card follows its bottom.
func _add_talk(id: int, speaker: String, color: Color, text: String, mine: bool) -> Dictionary:
	var entry := VBoxContainer.new(); entry.add_theme_constant_override("separation", 2)
	entry.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var who := Label.new(); who.text = speaker
	who.add_theme_font_size_override("font_size", 13); who.add_theme_color_override("font_color", color)
	var words := Label.new(); words.text = text
	words.add_theme_font_size_override("font_size", roundi(WORDS_SIZE * _text_scale()))
	words.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.visible_characters_behavior = TextServer.VC_CHARS_BEFORE_SHAPING
	words.visible_characters = 0
	for label: Label in [who, words]:
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if mine: label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		entry.add_child(label)
	_talk_log.add_child(entry)
	var row := {"actor": id, "text": text, "words": words, "done": false, "node": entry}
	_talk.append(row)
	while _talk.size() > TALK_LINES:
		(_talk.pop_front().node as Node).queue_free()
	for i in _talk.size():
		(_talk[i].node as Control).modulate.a = 1.0 if i >= _talk.size() - 2 else 0.6
	_talk_scroll.show()
	_follow_frames = 4
	return row

## Her coat colour, lifted until it reads on the dark card (as over her head).
func _speaker_color(actor: Node) -> Color:
	var identity: Variant = actor.get("identity") if is_instance_valid(actor) else null
	var coat: Variant = (identity as Resource).get("coat_fill") if identity is Resource else null
	return OVERHEAD._readable(coat as Color) if coat is Color else Color(1, 1, 1, 0.85)

func _subtitles_on() -> bool:
	var value: Variant = _setting("access/subtitles")
	return value == null or bool(value)

func _text_scale() -> float:
	var value: Variant = _setting("access/subtitle_scale")
	return clampf(float(value) / 100.0, 0.8, 1.6) if value != null else 1.0

func _setting(key: String) -> Variant:
	var settings := get_node_or_null("/root/Settings")
	return settings.call("get_value", key) if settings != null and settings.has_method("get_value") else null

## Under the lines: dots while somepony is working out what to say, or why nothing was heard.
func _talk_status() -> String:
	if not is_instance_valid(_voice_hud): return ""
	var state := str(_voice_hud.get("state"))
	var detail := str(_voice_hud.get("detail"))
	if state == "error": return detail
	if detail.begins_with("nobody in earshot"): return "Nopony heard that."
	if state == "thinking" and not detail.begins_with("Feedback"): return "• ".repeat(1 + int(_time * 3.0) % 3).strip_edges()
	return ""

func _tick_talk() -> void:
	var note := _talk_status()
	if _talk_note.text != note: _talk_note.text = note
	_talk_note.visible = note != ""
	var want := minf(_talk_log.get_combined_minimum_size().y, _talk_height())
	if absf(_talk_scroll.custom_minimum_size.y - want) > 0.5: _talk_scroll.custom_minimum_size.y = want
	if _follow_frames > 0:
		_follow_frames -= 1
		_talk_scroll.scroll_vertical = int(_talk_scroll.get_v_scroll_bar().max_value)

func _process(delta: float) -> void:
	if not is_instance_valid(table) or not bool(table.get("near")) or _got_up():
		close()
		return
	_time += delta
	_tick_talk()
	if is_instance_valid(camera) and _face.is_finite():
		var face := _face_point(_toward_player())
		if face.distance_to(_face) > 0.002:
			_face = _face.lerp(face, 1.0 - exp(-FACE_EASE * delta))
			_place_camera()
