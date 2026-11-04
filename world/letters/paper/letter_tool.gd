extends Node3D
## Writing paper and letters in a hand (docs/LETTERS_PLAN_2026_10_29.md section 7). Attached to
## the held item on first use (on()), like world/items/photo_camera.gd; briefcase_inventory.gd
## (desktop) and briefcase_vr_hands.gd (VR) forward the use button to press().
## - Blank paper ("goods:paper-<kind>"): use turns that sheet into a new draft letter
##   (letter_post.gd new_draft, inventory_store.gd replace_held, the same swap food uses for an
##   empty cup) and opens it to write: desktop typing (letter_paper.gd), VR the quill.
## - A draft: a short press opens it (desktop: to type) or folds it; holding the button SEND_SECONDS
##   sends it. Derpy comes for it (letter_courier.gd collect); at her grab the letter leaves the
##   hand and the briefcase. A small ring fills while the button is held.
## - A letter to read (hers, or one of his): use opens it in front of the eyes (book_hold.gd pose
##   rules), turns through a long letter's sides, then folds it. Desktop: the wheel brings it closer
##   and right click goes back a side. Her letter's first opening is recorded (post.set_status
##   "opened").
const STATIONERY := preload("res://world/letters/stationery.gd")
const BOOK_HOLD := preload("res://world/books/book_hold.gd")
const LETTER_ITEM := "res://world/letters/paper/letter_item.tscn"
const SEND_SECONDS := 1.0
## A press shorter than this shows no ring (an ordinary click).
const RING_AFTER := 0.15
const NOTICE_SECONDS := 3.5
## Desktop reading: the open sheet held up before the eyes, writing toward them, head of the page
## up (sheet +Y -> view +Z, sheet -Z -> view up), as book reading in briefcase_inventory.gd.
const READ_DESKTOP := Transform3D(Basis(Vector3.RIGHT, Vector3.BACK, Vector3.DOWN), Vector3(0, -0.03, -0.33))
const RING_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, shadows_disabled;
uniform float fill = 0.0;
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
}
void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	float r = length(p);
	float turn = fract(atan(p.x, -p.y) / 6.2831853 + 1.0);
	float band = smoothstep(0.62, 0.68, r) * (1.0 - smoothstep(0.92, 0.98, r));
	vec3 done = vec3(0.35, 0.62, 1.0);
	vec3 todo = vec3(1.0);
	ALBEDO = turn <= fill ? done : todo;
	ALPHA = band * (turn <= fill ? 0.95 : 0.35);
}
"""
static var _ring_shader: Shader
## Tests: Callable(side) -> bool standing in for the real button state (_button_down).
static var button_probe := Callable()
## VR: a hand's trigger counts as lost after this many physics ticks without a vr_step.
const VR_LOST_TICKS := 6

var item: Node3D
var _inventory: Node
var _press_side := ""
var _press_time := 0.0
## A short press uses the letter on release; false when the press only closed typing.
var _press_use := true
var _sent := false
var _sending := false
var _notice := ""
var _notice_until := 0.0
var _ring: MeshInstance3D
var _vr_down: Dictionary = {}
var _vr_seen: Dictionary = {}
var _send_check := {}
var _send_check_at := -10.0
var _shown_text := "\u0000"

static func on(held_item: Node3D) -> Node3D:
	var tool := held_item.get_node_or_null("LetterTool") as Node3D
	if tool != null: return tool
	tool = (load("res://world/letters/paper/letter_tool.gd") as GDScript).new()
	tool.name = "LetterTool"; tool.item = held_item
	held_item.add_child(tool)
	return tool

## Items this tool serves: writing paper and letters.
static func handles(held_item: Node) -> bool:
	if not is_instance_valid(held_item): return false
	var id := str(held_item.get_meta("item_id", ""))
	return not STATIONERY.of_item(id).is_empty() or (id.begins_with("letter:") and held_item.get_node_or_null("LetterSheet") != null)

func _ready() -> void:
	set_process(false)

func letter_sheet() -> Node3D:
	return item.get_node_or_null("LetterSheet") as Node3D if is_instance_valid(item) else null

func letter_id() -> String:
	var id := str(item.get_meta("item_id", "")) if is_instance_valid(item) else ""
	return id.substr(7) if id.begins_with("letter:") else ""

func _post() -> Node:
	return get_tree().get_first_node_in_group("letter_post") if is_inside_tree() else null

func _paper() -> Node:
	return get_tree().get_first_node_in_group("letter_paper") if is_inside_tree() else null

func row() -> Dictionary:
	var post := _post()
	var id := letter_id()
	if post == null or id.is_empty(): return {}
	var found: Variant = post.call("row", id)
	return found as Dictionary if found is Dictionary else {}

func is_draft() -> bool:
	var letter := row()
	return str(letter.get("status", "")) == "draft" and str(letter.get("from", "player")) == "player"

## The use button went down or up on this hand ("desktop", "left" or "right"). A draft waits for
## the release (short: use) or SEND_SECONDS (send); anything else is used at once.
func press(inventory: Node, side: String, down: bool) -> void:
	_inventory = inventory
	if down:
		if not _press_side.is_empty(): return
		if not is_draft():
			use(inventory, side); return
		_press_side = side; _press_time = 0.0; _press_use = true; _sent = false
		set_process(true)
		return
	if _press_side != side: return
	var short := _press_time < SEND_SECONDS and not _sent
	_press_side = ""
	_show_ring(0.0, false)
	if short and _press_use: use(inventory, side)

## Desktop: a click that ends typing may still be held to send (letter_paper.gd).
func hold_after_typing(inventory: Node, side: String) -> void:
	_inventory = inventory
	_press_side = side; _press_time = 0.0; _press_use = false; _sent = false
	set_process(true)

## The short press.
func use(inventory: Node, side: String) -> bool:
	_inventory = inventory
	var kind := STATIONERY.of_item(str(item.get_meta("item_id", "")))
	if not kind.is_empty(): return _start_letter(inventory, side, kind)
	var sheet := letter_sheet()
	if sheet == null: return false
	if is_draft():
		if side == "desktop":
			var paper := _paper()
			if paper == null: return false
			if not sheet.opened: _open(sheet)
			if not bool(paper.call("begin_typing", letter_id(), item, inventory)):
				sheet.fold(); return false
			return true
		if sheet.opened: sheet.fold()
		else: _open(sheet)
		return true
	if not sheet.opened:
		_open(sheet)
		var letter := row()
		if str(letter.get("from", "player")) != "player" and str(letter.get("status", "")) in ["in_mailbox", "taken"]:
			var post := _post()
			if post != null: post.call("set_status", letter_id(), "opened")
	elif sheet.more_pages(): sheet.next_page()
	else: sheet.fold()
	return true

func _open(sheet: Node3D) -> void:
	refresh_sheet()
	sheet.open_sheet()
	_place_sheet(null)
	set_process(true)

## Shows the letter's stored text on the sheet (or `live` while it is being typed).
func refresh_sheet(live: Variant = null) -> void:
	var sheet := letter_sheet()
	if sheet == null: return
	var letter := row()
	var text: String = str(live) if live is String else str(letter.get("text", ""))
	sheet.follow_end = is_draft()
	if text == _shown_text and live == null: return
	_shown_text = text
	sheet.refresh(text, str(letter.get("stationery", "plain")), str(letter.get("from", "player")) != "player")

## Blank paper becomes a draft: a row in the post, the held unit becomes "letter:<id>" in the same
## loan, and the visual becomes the letter, opened to write.
func _start_letter(inventory: Node, side: String, kind: String) -> bool:
	var post := _post()
	if post == null:
		say("Letters can't be written here yet"); return false
	var token := str(item.get_meta("token", ""))
	var store: Object = inventory.get("inventory")
	if store == null or not (store.get("loans") as Dictionary).has(token): return false
	var id := str(post.call("new_draft", kind))
	if id.is_empty():
		say("Letters can't be written here yet"); return false
	if not bool(store.call("replace_held", token, "letter:" + id)):
		say(str(store.get("last_error")) if not str(store.get("last_error")).is_empty() else "Couldn't start the letter"); return false
	swap_visual(item, "letter:" + id)
	if inventory.has_method("_refresh_holding"): inventory.call("_refresh_holding")
	return use(inventory, side)

## The held body keeps its token and grip; its look becomes a letter_item.tscn.
static func swap_visual(held_item: Node3D, id: String) -> Node3D:
	var old: Node = held_item.get_child(1) if held_item.get_child_count() > 1 else null
	var visual: Node3D = (load(LETTER_ITEM) as PackedScene).instantiate()
	visual.set("item_id", id)
	held_item.set_meta("item_id", id)
	if old != null and not old is CollisionShape3D:
		held_item.remove_child(old); old.queue_free()
	held_item.add_child(visual)
	# The briefcase treats child 1 as the item's visual (briefcase_vr_hands.gd _store_at_wrist).
	held_item.move_child(visual, 1)
	var shape := held_item.get_child(0) as CollisionShape3D
	if shape != null: visual.call("configure_body", held_item, shape)
	return visual

## Holding a draft SEND_SECONDS: Derpy is asked to come for it.
func send(inventory: Node, side: String) -> bool:
	var post := _post()
	var id := letter_id()
	if post == null or id.is_empty(): return false
	var check: Dictionary = post.call("can_send", id)
	if not bool(check.get("ok", false)):
		say(str(check.get("reason", "Not ready to send"))); return false
	var courier: Node = get_tree().get_first_node_in_group("letter_courier")
	if courier == null:
		say("Derpy isn't flying today"); return false
	var paper := _paper()
	if paper != null and bool(paper.call("typing")): paper.call("end_typing")
	var sheet := letter_sheet()
	if sheet != null: sheet.fold()
	var result: Dictionary = courier.call("collect", id, item, side, _taken.bind(weakref(inventory)))
	if not bool(result.get("ok", false)):
		say(str(result.get("reason", "Derpy can't come right now"))); return false
	_sending = true
	say("Derpy is coming for your letter to %s" % str(check.get("to_name", "her")))
	return true

## The courier's grab: the letter leaves the hand and the briefcase (called once by collect).
func _taken(inventory_ref: WeakRef) -> void:
	var inventory: Node = inventory_ref.get_ref()
	if not is_instance_valid(item): return
	var token := str(item.get_meta("token", ""))
	if is_instance_valid(inventory):
		var store: Object = inventory.get("inventory")
		if store != null: store.call("consume", token)
		var held: Dictionary = inventory.get("held")
		for hand: String in held.keys():
			if held[hand] == item:
				held.erase(hand)
				if inventory.get("_track") is Dictionary: (inventory.get("_track") as Dictionary).erase(hand)
				if inventory.has_method("_claim"): inventory.call("_claim", hand, false)
		var loose: Variant = inventory.get("loose")
		if loose is Dictionary: (loose as Dictionary).erase(token)
		if inventory.has_method("_refresh_holding"): inventory.call("_refresh_holding")
	item.queue_free()

func say(text: String, seconds := NOTICE_SECONDS) -> void:
	_notice = text
	_notice_until = Time.get_ticks_msec() * 0.001 + seconds

func _process(delta: float) -> void:
	if not is_instance_valid(item): return
	var holding := not _press_side.is_empty()
	if holding and not _button_down(_press_side):
		# The release never reached us (Tab, Esc, alt-tab, lost hand tracking): no use, no send.
		_press_side = ""; holding = false
		_show_ring(0.0, false)
	if holding:
		_press_time += delta
		if _press_time >= SEND_SECONDS and not _sent:
			_sent = true
			_show_ring(0.0, false)
			if is_instance_valid(_inventory): send(_inventory, _press_side)
		elif not _sent:
			_show_ring(_press_time / SEND_SECONDS, _press_time >= RING_AFTER)
	if _sending:
		# A swoop that ended before the grab leaves the letter in hand: it can be sent again.
		var courier: Node = get_tree().get_first_node_in_group("letter_courier")
		if courier == null or not bool(courier.call("busy")): _sending = false
	var sheet := letter_sheet()
	var open: bool = sheet != null and bool(sheet.opened)
	# Out of the hand (thrown, set down, stashed, shelved) an open letter folds. Placing it before
	# the eyes regardless left it stuck in his face with nothing in hand to fold it (dev 2026-10-30).
	if open and not _in_hand():
		var paper := _paper()
		if paper != null and bool(paper.call("typing")): paper.call("end_typing")
		sheet.fold(); open = false
	if open and is_instance_valid(_inventory) and bool(_inventory.get("_desktop")): _place_sheet(null)
	if not holding and not _sending and not open: set_process(false)

## Whether a hand still holds this letter.
func _in_hand() -> bool:
	if not is_instance_valid(_inventory): return false
	var held: Variant = _inventory.get("held")
	return held is Dictionary and (held as Dictionary).values().has(item)

## The use button is still held: desktop either mouse button, VR a hand still reporting its
## trigger every physics tick (vr_step).
func _button_down(side: String) -> bool:
	if button_probe.is_valid(): return bool(button_probe.call(side))
	if side == "desktop": return Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	return Engine.get_physics_frames() - int(_vr_seen.get(side, -1000)) <= VR_LOST_TICKS

## The open sheet's pose: before the eyes on desktop, up from the hand in VR (book_hold.gd).
func _place_sheet(sample: Variant) -> void:
	var sheet := letter_sheet()
	if sheet == null or not sheet.opened or not is_instance_valid(_inventory): return
	var eye: Camera3D = _inventory.get("camera")
	if eye == null: return
	if bool(_inventory.get("_desktop")) or not sample is Dictionary:
		sheet.place(eye.global_transform * sheet.reading_pose(READ_DESKTOP))
	else:
		var current: Basis = sheet.sheet.global_basis if sheet.sheet != null else Basis()
		sheet.place(BOOK_HOLD.from_hand(sample, eye.global_transform, current, true))

## VR, every physics tick in hand: the trigger (hysteresis like the books) and the sheet's pose.
func vr_step(inventory: Node, side: String, sample: Dictionary) -> void:
	_inventory = inventory
	_vr_seen[side] = Engine.get_physics_frames()
	var was: bool = _vr_down.get(side, false)
	var down := float(sample.get("trigger", 0.0)) > (0.3 if was else 0.7)
	if down != was:
		_vr_down[side] = down
		press(inventory, side, down)
	if sample.get("active", false): _place_sheet(sample)

func _show_ring(fill: float, visible_: bool) -> void:
	if not visible_:
		if is_instance_valid(_ring): _ring.hide()
		return
	if not is_instance_valid(_ring):
		if _ring_shader == null:
			_ring_shader = Shader.new(); _ring_shader.code = RING_SHADER
		_ring = MeshInstance3D.new(); _ring.name = "SendRing"
		var quad := QuadMesh.new(); quad.size = Vector2(0.045, 0.045)
		_ring.mesh = quad
		var material := ShaderMaterial.new(); material.shader = _ring_shader
		material.render_priority = 100
		_ring.material_override = material
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_ring.top_level = true
		add_child(_ring)
	(_ring.material_override as ShaderMaterial).set_shader_parameter("fill", clampf(fill, 0.0, 1.0))
	var eye: Camera3D = _inventory.get("camera") if is_instance_valid(_inventory) else null
	var at := item.global_position + Vector3.UP * 0.08
	if eye != null and bool(_inventory.get("_desktop")): at = eye.global_transform * Vector3(0, -0.06, -0.3)
	_ring.global_position = at
	_ring.show()

## The control hint for this item in `side`'s hand (briefcase_inventory.gd interaction_hint).
func hint(side: String) -> Dictionary:
	var desktop := side == "desktop"
	var click := "Click" if desktop else "Trigger"
	var text := ""
	var id := str(item.get_meta("item_id", ""))
	var sheet := letter_sheet()
	if not STATIONERY.of_item(id).is_empty():
		text = "%s · Write a letter" % click
	elif is_draft():
		if _sending: text = "Derpy is coming for your letter"
		else:
			var opened: bool = sheet != null and sheet.opened
			text = ("%s · Write" % click) if desktop else ("Trigger · Fold" if opened else "Trigger · Open")
			if opened and not desktop: text = "Quill to the paper · Speak to write   " + text
			var check := _send_status()
			if bool(check.get("ok", false)): text += "   Hold %s · Send to %s" % [click.to_lower() if desktop else "trigger", str(check.get("to_name", ""))]
	else:
		var opened: bool = sheet != null and sheet.opened
		text = "%s · %s" % [click, "Read" if not opened else ("Next page" if sheet.more_pages() else "Fold")]
		if opened and desktop:
			text += "   Wheel · Closer"
			if sheet.page > 0: text += "   Right click · Back"
	if Time.get_ticks_msec() * 0.001 < _notice_until and not _notice.is_empty(): text = _notice + "   " + text
	return {"target": item, "text": text, "point": item.global_position + Vector3.UP * 0.12, "outline": null}

## can_send, asked at most twice a second for the hint.
func _send_status() -> Dictionary:
	var now := Time.get_ticks_msec() * 0.001
	if now - _send_check_at < 0.5: return _send_check
	_send_check_at = now
	var post := _post()
	_send_check = post.call("can_send", letter_id()) if post != null and not letter_id().is_empty() else {}
	return _send_check
