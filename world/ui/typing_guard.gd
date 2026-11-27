extends Node
## Typing never drives the game (dev 2026-11-09: "typing the letter q while in bed makes you get up").
## While a LineEdit or TextEdit in the game window has focus, every key belongs to that field:
## - InputMap: the keyboard events of every gameplay action (actions not named ui_*) are taken out
##   and held actions are released, so Input.is_action_pressed / event.is_action see nothing; they
##   are put back when the field loses focus (0.3.1).
## - Every other route (2026-11-19 thread fix, docs/THREAD_FIX_TYPING_KEYS_2026_11_19.md): a key
##   pressed while typing reaches the game blank. The root window's window_input signal fires before
##   any _input handler, the GUI and _unhandled_input; there the key event loses its keycode, physical
##   keycode and key label (the field still types its character: LineEdit and TextEdit insert from
##   `unicode`), and a release of it is parsed at once so Input.is_key_pressed /
##   is_physical_key_pressed polls see it up. Its real release later is blanked too. Mods get this
##   without doing anything: Dance Mod's polled Y, Kissing's Shift+K in _input, the game's CapsLock
##   companion pace and F-keys all stay quiet. Keys the field itself uses (FIELD_KEYS, Ctrl/Cmd edit
##   shortcuts, the developer console's ` toggle) pass unchanged; the game's handlers for those check
##   active() themselves. A key held before typing began keeps its release, so latches let go.
## Not covered: joypads (not keys), text fields in a SubViewport or another OS window (VR panels:
## their keys never come through the game window), and InputMap actions a mod adds while typing.
## Made by Settings (autoload/settings.gd); event-driven, no per-frame work: one cast per input event.

## Rollback switch: false = 0.3.1 behaviour (InputMap stash only; raw key reads see typed letters).
const SILENCE_KEYS := true
## Keys a text field edits or leaves with. They reach the game as they are, also while typing.
const FIELD_KEYS: Array[Key] = [KEY_ENTER, KEY_KP_ENTER, KEY_ESCAPE, KEY_TAB, KEY_BACKSPACE, KEY_DELETE,
	KEY_INSERT, KEY_LEFT, KEY_RIGHT, KEY_UP, KEY_DOWN, KEY_HOME, KEY_END, KEY_PAGEUP, KEY_PAGEDOWN, KEY_MENU,
	KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]
## With Ctrl or Cmd (not AltGr, which is Ctrl+Alt): select all, copy, paste, cut, undo, redo.
const EDIT_SHORTCUTS: Array[Key] = [KEY_A, KEY_C, KEY_V, KEY_X, KEY_Z, KEY_Y]
## Marks the release this guard parses for a silenced press.
const OWN_RELEASE := &"typing_guard_release"
const DEV := preload("res://world/dev_tools.gd")

static var _typing := false
var _stashed: Dictionary = {}   # action -> Array[InputEvent] taken out while typing
var _swallowed: Dictionary = {}   # key code -> true: pressed while typing; its release is silenced too


## True while a text field has focus (cheap; kept current by the focus signal).
static func active() -> bool:
	return _typing


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_viewport().gui_focus_changed.connect(_on_focus)
	# Settings is made before Mods: connected first, so this runs before any mod's own listener.
	if SILENCE_KEYS: get_window().window_input.connect(_on_window_input)


func _on_focus(node: Control) -> void:
	var now := node is LineEdit or node is TextEdit
	# Every focused field is watched: focus can go from one field straight to another and then away.
	if now: _watch(node)
	if now == _typing: return
	_typing = now
	if now: _stash()
	else: _restore()


## A focused field that leaves the tree or hides never sends a focus change: watch it.
func _watch(node: Control) -> void:
	# A bound method, not a lambda capturing the field (it may be freed when this runs); one
	# connection per field however often it is focused.
	var lost := Callable(self, "_field_lost")
	if not node.focus_exited.is_connected(lost): node.focus_exited.connect(lost, CONNECT_ONE_SHOT | CONNECT_DEFERRED)
	if not node.tree_exiting.is_connected(lost): node.tree_exiting.connect(lost, CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _field_lost() -> void:
	if not _typing or not is_inside_tree(): return
	var focus := get_viewport().gui_get_focus_owner()
	if not (focus is LineEdit or focus is TextEdit):
		_typing = false; _restore()


## Before any _input handler: a key typed into a field reaches the game blank (header).
func _on_window_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null: return
	if key.has_meta(OWN_RELEASE):
		_silence(key); return
	var code: int = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if not key.pressed:
		if _swallowed.erase(code): _silence(key)
		return
	if not _typing or _field_key(key):
		# A fresh press outside typing owns its release again (a release lost to a window switch).
		if not key.echo: _swallowed.erase(code)
		return
	if not key.echo:
		_swallowed[code] = true
		var up := key.duplicate() as InputEventKey
		up.pressed = false; up.echo = false; up.unicode = 0
		up.set_meta(OWN_RELEASE, true)
		Input.parse_input_event(up)
	_silence(key)


## Keys the focused field uses itself: they pass unchanged.
func _field_key(key: InputEventKey) -> bool:
	var code: int = key.keycode if key.keycode != KEY_NONE else key.physical_keycode
	if code in FIELD_KEYS: return true
	if (key.ctrl_pressed or key.meta_pressed) and not key.alt_pressed and code in EDIT_SHORTCUTS: return true
	# The developer console (world/debug/command_console.gd) closes on the key it opens with.
	return key.physical_keycode == KEY_QUOTELEFT and DEV.enabled()


static func _silence(key: InputEventKey) -> void:
	key.keycode = KEY_NONE; key.physical_keycode = KEY_NONE; key.key_label = KEY_NONE


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
