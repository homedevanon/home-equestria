extends CanvasLayer
const OWNER := preload("res://player/desktop_action_owner.gd")
## Desktop: press Enter to type what Anon says, Enter again to say it, Escape to cancel.
## The line goes to the conversation director exactly like recognised speech.
var director: Node
var player: Node
var inventory: Node
var field: LineEdit
var _mouse_before := Input.MOUSE_MODE_CAPTURED
var _lock_owned := false
## Player meta while the field is open: the movement lock is the chat's, so a carried pony and
## his posture stay as they are (player/desktop_interactions.gd _keeps_carry).
const TYPING_META := "chat_typing"

func setup(conversation: Node, body: Node, items: Node = null) -> void:
	director = conversation; player = body; inventory = items
	layer = 20
	var panel := PanelContainer.new()
	panel.anchor_left = 0.5; panel.anchor_right = 0.5; panel.anchor_top = 1.0; panel.anchor_bottom = 1.0
	panel.offset_left = -330; panel.offset_right = 330; panel.offset_top = -150; panel.offset_bottom = -104
	var style := StyleBoxFlat.new(); style.bg_color = Color(0.08, 0.09, 0.1, 0.78); style.set_corner_radius_all(8)
	style.content_margin_left = 12; style.content_margin_right = 12; style.content_margin_top = 6; style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	add_child(panel)
	# Pony speech captions sit above the field while it is open (world/ui/speech_caption.gd).
	panel.add_to_group("caption_clearance")
	field = LineEdit.new(); field.placeholder_text = "Say something…  (Enter to say, Esc to cancel)"
	field.max_length = 400; field.add_theme_font_size_override("font_size", 20)
	field.text_submitted.connect(_submit)
	panel.add_child(field)
	visible = false

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo: return
	var key: int = event.physical_keycode
	if visible:
		if key == KEY_ESCAPE: _close(); get_viewport().set_input_as_handled()
		return
	if key != KEY_ENTER and key != KEY_KP_ENTER: return
	# Only from ordinary play: no menu, map, briefcase or other text field open.
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit: return
	if _open(): get_viewport().set_input_as_handled()

func _open() -> bool:
	if visible or not is_instance_valid(player): return false
	if "controls_locked" in player and player.controls_locked:
		var activity := OWNER.current(inventory)
		if activity == null or not activity.has_method("owns_control_lock") or not activity.owns_control_lock(): return false
	# Typing no longer cancels what Anon is doing (2026-10-28 player report: Enter stood him up
	# and dropped the mare he carried). Movement is locked while the field is open.
	visible = true
	_mouse_before = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if "controls_locked" in player:
		_lock_owned = not player.controls_locked
		player.controls_locked = true
	player.set_meta(TYPING_META, true)
	field.text = ""
	field.grab_focus()
	return true

func _submit(text: String) -> void:
	_close()
	if text.strip_edges() != "" and is_instance_valid(director): director.handle_text(text)

func _close() -> void:
	if not visible: return
	if is_instance_valid(field) and field.is_inside_tree(): field.release_focus()
	visible = false
	if is_instance_valid(player) and player.has_meta(TYPING_META): player.remove_meta(TYPING_META)
	if _lock_owned and is_instance_valid(player): player.controls_locked = false
	_lock_owned = false
	Input.mouse_mode = _mouse_before

func _exit_tree() -> void:
	_close()
