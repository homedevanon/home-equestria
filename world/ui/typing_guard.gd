extends Node
## Typing never drives the game (dev 2026-11-09: "typing the letter q while in bed makes you get up").
## While a LineEdit or TextEdit has focus, the keyboard events of every gameplay action (InputMap
## actions not named ui_*) are taken out of the InputMap and held actions are released, so code that
## polls Input.is_action_pressed / event.is_action (base game and mods alike) sees nothing; they are
## put back when the text field loses focus. Raw keycode checks in _input handlers use active().
## Made by Settings (autoload/settings.gd); event-driven, no per-frame work.

static var _typing := false
var _stashed: Dictionary = {}   # action -> Array[InputEvent] taken out while typing


## True while a text field has focus (cheap; kept current by the focus signal).
static func active() -> bool:
	return _typing


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_viewport().gui_focus_changed.connect(_on_focus)


func _on_focus(node: Control) -> void:
	var now := node is LineEdit or node is TextEdit
	if now == _typing: return
	_typing = now
	if now: _stash()
	else: _restore()
	if now: _watch(node)


## A focused field that leaves the tree or hides never sends a focus change: watch it.
func _watch(node: Control) -> void:
	# No capture of the field itself: it may already be freed when this runs.
	var lost := func() -> void:
		if not _typing or not is_inside_tree(): return
		var focus := get_viewport().gui_get_focus_owner()
		if not (focus is LineEdit or focus is TextEdit):
			_typing = false; _restore()
	if not node.focus_exited.is_connected(lost): node.focus_exited.connect(lost, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	if not node.tree_exiting.is_connected(lost): node.tree_exiting.connect(lost, CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _stash() -> void:
	for action: StringName in InputMap.get_actions():
		if String(action).begins_with("ui_"): continue
		var keys: Array[InputEvent] = []
		for event: InputEvent in InputMap.action_get_events(action):
			if event is InputEventKey: keys.append(event)
		if keys.is_empty(): continue
		for event: InputEvent in keys: InputMap.action_erase_event(action, event)
		_stashed[action] = keys
		Input.action_release(action)


func _restore() -> void:
	for action: StringName in _stashed:
		if not InputMap.has_action(action): continue
		for event: InputEvent in _stashed[action]:
			if not InputMap.action_has_event(action, event): InputMap.action_add_event(action, event)
	_stashed.clear()


func _exit_tree() -> void:
	_restore()
