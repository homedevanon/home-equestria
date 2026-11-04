extends Node
## Contextual desktop actions. One active hand, with a supporting hand for carries.
## This adapter supplies deliberate commands and presentation targets, never XR tracking.
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const OWNER := preload("res://player/desktop_action_owner.gd")
const TOUCH_REACH := 1.6
const CONTACT_SECONDS := .16
const STROKE_SECONDS := .7
## Where his palms rest relative to her chest's side grips while carrying (negative = inside them).
const CARRY_PALM := -.03
## Bridal carry: how far below her spine and thighs his palms rest.
const CRADLE_UNDER := .1
var camera: Camera3D
var body: Node3D
var inventory: Node
var interactor: Node
var _action := ""
var _target: Node3D
var _offer: Dictionary = {}
var _point := Vector3.ZERO
var _normal := Vector3.UP
var _time := 0.0
var _used := false
var _pressed := false
var _hoof_anchor := Vector3.ZERO
var _slap_until := 0
var _avatar: Node
var _held_pose := false
## Bridal carried, the controls move to a card in the corner (cradle_controls.gd); the row under
## the crosshair sat where her subtitles go.
var _cradle_controls: CanvasLayer
var _cradle_rows_in := 0.0
var _cradle_rows: Array = []


func setup(view: Camera3D, movement: Node3D, items: Node, reach: Node) -> void:
	camera = view; body = movement; inventory = items; interactor = reach
	add_to_group("desktop_interactions")
	add_to_group("interaction_hint_sources")
	process_physics_priority = -30
	if is_instance_valid(interactor): interactor.desktop_actions = self
	call_deferred("_bind_presentation")


func _bind_presentation() -> void:
	if not is_instance_valid(inventory) or not "desktop_presentation" in inventory: return
	_avatar = inventory.desktop_presentation
	if is_instance_valid(_avatar) and _avatar.has_signal("action_contact") and not _avatar.action_contact.is_connected(_action_contact):
		_avatar.action_contact.connect(_action_contact)


func _present(kind: String, point: Vector3, normal: Vector3) -> bool:
	if not is_instance_valid(_avatar): _bind_presentation()
	if not is_instance_valid(_avatar): return false
	if kind in ["carry", "hoof_hold"]:
		var facing := camera.global_basis.orthonormalized()
		var right := point
		if kind == "carry":
			# A hand at her chest grip sinks into her chest whichever way she faces: hold her sides.
			var across := camera.global_basis.x * (_carry_half_width() + CARRY_PALM)
			right = point + across
			var left := point - across
			# Bridal carry: his left hand behind her upper back and neck, his right under her hind
			# legs, mid-gaskin (the hocks ride too high for his reach).
			var cradled := smoothstep(0.0, 1.0, interactor.cradle_amount())
			if cradled > 0.0:
				var pony: Node3D = interactor.held
				var size := float(pony.get("body_scale") if pony.get("body_scale") != null else 1.0)
				var pivot: Node3D = pony.get("pivot")
				var back: Vector3 = (pony.global_basis * pivot.transform.basis).orthonormalized() * Vector3.UP if pivot != null else Vector3.DOWN
				left = left.lerp(_bone_point(pony, ["pony_spine1", "pony_neck1"]) + back * CRADLE_UNDER * size, cradled)
				right = right.lerp(_bone_point(pony, ["pony_tibia_L", "pony_tibia_R", "pony_legLower_L", "pony_legLower_R"]) + Vector3.DOWN * CRADLE_UNDER * .6 * size, cradled)
			_avatar.set_hold_target("left", Transform3D(facing, left), "hold")
		_avatar.set_hold_target("right", Transform3D(facing, right), "hold")
		_held_pose = true
		return true
	if kind == "pet" and _avatar.update_action_target(kind, point, normal): return true
	return _avatar.request_action(kind, point, normal)


## The average world position of these bones of hers (her grip point if none are found).
func _bone_point(pony: Node3D, names: Array) -> Vector3:
	var skeleton: Skeleton3D = pony.get("skeleton")
	var sum := Vector3.ZERO
	var found := 0
	for bone_name: String in names:
		var bone := skeleton.find_bone(bone_name) if skeleton != null else -1
		if bone < 0: continue
		sum += skeleton.global_transform * skeleton.get_bone_global_pose(bone).origin
		found += 1
	return sum / found if found > 0 else pony.get_grip_transform("chest").origin


## Half her chest's width, from her own side grips, so it fits foals and grown ponies alike.
func _carry_half_width() -> float:
	var pony: Node3D = interactor.held
	return pony.get_grip_transform("left_chest").origin.distance_to(pony.get_grip_transform("right_chest").origin) * .5


func busy() -> bool:
	return not _action.is_empty() or (is_instance_valid(interactor) and is_instance_valid(interactor.held))


func _human() -> bool:
	return not PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()))


func _available() -> bool:
	if not is_instance_valid(camera) or not is_instance_valid(body) or not is_instance_valid(inventory): return false
	if get_tree().paused or body.get("controls_locked") == true or body.get_meta("knocked_down", false): return false
	if body.get("flying") == true or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return false
	if not _human(): return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	return true


func can_accept_world_action() -> bool:
	if not _available() or inventory.held.has("desktop") or inventory.holding_case == "desktop": return false
	var owner: Variant = inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
	return not is_instance_valid(owner) or owner == self


func _social_free() -> bool:
	if not can_accept_world_action() or (is_instance_valid(interactor) and is_instance_valid(interactor.held)): return false
	var host: Node = inventory.get_parent()
	var kisser: Variant = host.get("kisser") if "kisser" in host else null
	if is_instance_valid(kisser) and is_instance_valid(kisser.get("_active")): return false
	var cuddle: Node = get_tree().get_first_node_in_group("cuddle_input")
	return not is_instance_valid(cuddle) or not is_instance_valid(cuddle.current)


func _ponies() -> Array:
	var host: Node = inventory.get_parent()
	var actors: Variant = host.get("mares") if "mares" in host else null
	return actors if actors is Array else []


func _clear_to(point: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, point, 1 | 8 | (1 << 17))
	return camera.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _select(slap: bool = false) -> Dictionary:
	var origin := camera.global_position
	var reach := TOUCH_REACH
	if is_instance_valid(_avatar) and is_instance_valid(_avatar.avatar): reach = minf(reach, _avatar.MAX_REACH*float(_avatar.avatar.model_scale))
	var end := origin - camera.global_basis.z * reach
	var closest := reach + .001
	var best: Dictionary = {}
	for actor: Variant in _ponies():
		if not is_instance_valid(actor) or not actor.is_inside_tree() or not actor.is_visible_in_tree(): continue
		if actor.global_position.distance_squared_to(origin) > 9.0 or actor.is_held(): continue
		var touch: Node = actor.get("touch_body")
		if not is_instance_valid(touch): continue
		var hit: Dictionary = touch.desktop_offer(origin, end)
		if hit.is_empty(): continue
		var distance: float = origin.distance_to(hit.point)
		if distance >= closest: continue
		closest = distance; best = hit
	if best.is_empty(): return {}
	if slap:
		var identity: Resource = best.target.get("identity")
		if identity != null and bool(identity.get("filly")): return {}
		var flank: Node = best.target.get_node_or_null("FlankTouch")
		if flank == null:
			for child: Node in best.target.get_children():
				if child.has_method("desktop_impact"): flank = child; break
		if flank == null: return {}
		var hit: Dictionary = flank.desktop_offer(origin, end)
		if hit.is_empty() or not _clear_to(hit.point): return {}
		# A head/leg between the eye and rear patch remains an obstruction.
		if Vector3(best.point).distance_to(hit.point) > .16: return {}
		hit.flank = flank
		return hit
	var boop: Node = best.target.get("boop_node")
	if is_instance_valid(boop):
		var nose: Vector3 = boop.nose_world()
		if Vector3(best.point).distance_to(nose) < .065:
			best.kind = "boop"; best.point = nose
			return best
	best.kind = "pet"
	return best


func _claim() -> void:
	OWNER.claim(inventory, self)


func _unclaim() -> void:
	OWNER.release(inventory, self)


func cancel_desktop_activity() -> void:
	if _keeps_cradle(): return
	_finish()
	if _carry_waits_for_ground(): return
	if is_instance_valid(interactor) and is_instance_valid(interactor.held): interactor._drop()


## Bridal carried, she stays in his arms through chat, menus and alt-tab: only he puts her down
## (G, or carrying her normally first). Knocked down, flying or in pony form still lets go.
func _keeps_cradle() -> bool:
	return is_instance_valid(interactor) and is_instance_valid(interactor.held) and interactor.cradled 		and is_instance_valid(camera) and is_instance_valid(body) and not body.get_meta("knocked_down", false) 		and body.get("flying") != true and _human()


## A carried pony is never let go by the chat box, a menu, the map or alt-tab while he is in
## the air or she is held out over a drop (thread 43671981: Starlight fell into the pit outside
## Canterlot when he wing-flew with her and typed to her). That release waits until he stands on
## ground with ground close under her; his own G tap or throw still lets go at once, and knocked
## down, debug fly or pony form still let go as before.
func _carry_waits_for_ground() -> bool:
	if not is_instance_valid(interactor) or not is_instance_valid(interactor.held) or not is_instance_valid(body): return false
	if body.get_meta("knocked_down", false) or body.get("flying") == true or not _human(): return false
	var wings: Variant = body.get("wing_flight")
	if wings is Object and (wings as Object).get("active") == true: return true
	if body is CharacterBody3D and not (body as CharacterBody3D).is_on_floor(): return true
	return over_drop(interactor.held, [body])

## Ground she would fall onto is this far below her when let go: more is a drop.
const SAFE_DROP := 1.6

## True when nothing solid lies within SAFE_DROP metres straight below `pony`.
static func over_drop(pony: Node3D, exclude_bodies: Array = []) -> bool:
	if not is_instance_valid(pony) or not pony.is_inside_tree() or pony.get_world_3d() == null: return false
	var excluded: Array[RID] = []
	for item: Variant in [pony] + exclude_bodies:
		if item is CollisionObject3D and is_instance_valid(item): excluded.append((item as CollisionObject3D).get_rid())
	var from := pony.global_position + Vector3.UP * .2
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * (SAFE_DROP + .2))
	query.exclude = excluded
	return pony.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _begin(action: String, offer: Dictionary) -> bool:
	if offer.is_empty() or not _action.is_empty() or not _social_free(): return false
	_action = action; _target = offer.target; _offer = offer
	_point = offer.point; _normal = offer.normal; _time = 0.0; _used = false
	_claim()
	if not _present(action, _point, _normal): _finish(); return false
	return true


func _begin_hoof(offer: Dictionary) -> bool:
	if offer.is_empty() or not _social_free(): return false
	var hoof: RefCounted = offer.target.get("hoof_hold")
	if hoof == null: return false
	var hit: Dictionary = hoof.candidate(offer.point, .12)
	if hit.is_empty() or not hoof.begin(hit, offer.point): return false
	if not _begin("hoof_hold", offer):
		hoof.release(); return false
	_hoof_anchor = camera.to_local(offer.point)
	if not _target.has_meta("spa_client"): _target.physical_reaction.emit("hoofhold")   # spa care is not a hoof-hold
	return true


func _input(event: InputEvent) -> void:
	# Releases must reach this owner even when a panel consumes the original button.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_pressed = false
		if _action == "pet": _finish()
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_H, KEY_K, KEY_C, KEY_G]:
		# Letters typed into the chat box (world/ui/chat_box.gd) are words, not hug/kiss/grab keys.
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return
		if _action in ["pet", "hoof_hold"]: _finish()


func _unhandled_input(event: InputEvent) -> void:
	if not _available() or FLIGHT_INPUT.reserves_mouse(event, body): return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode == KEY_E:
		if _action == "hoof_hold":
			_finish(); get_viewport().set_input_as_handled(); return
		if _social_free():
			var offer := _select()
			if _begin_hoof(offer): get_viewport().set_input_as_handled()
		return
	if not event is InputEventMouseButton or not event.pressed: return
	if not _social_free() or not _action.is_empty(): return
	if event.button_index == MOUSE_BUTTON_LEFT:
		var offer := _select()
		if not offer.is_empty() and _begin(offer.kind, offer):
			_pressed = true; get_viewport().set_input_as_handled()
	elif event.button_index == MOUSE_BUTTON_RIGHT and Time.get_ticks_msec() >= _slap_until:
		var offer := _select(true)
		if _begin("slap", offer):
			_slap_until = Time.get_ticks_msec() + 450
			get_viewport().set_input_as_handled()


func _physics_process(delta: float) -> void:
	_update_cradle_controls(delta)
	if not _available():
		if _keeps_cradle():
			_present("carry", interactor.held.get_grip_transform("chest").origin, -camera.global_basis.z)
			return
		_finish()
		if _carry_waits_for_ground():
			# Held on until he has landed (_carry_waits_for_ground); the drop below runs then.
			if is_instance_valid(camera): _present("carry", interactor.held.get_grip_transform("chest").origin, -camera.global_basis.z)
			return
		if is_instance_valid(interactor) and is_instance_valid(interactor.held): interactor._drop()
		return
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		_claim()
		var grip: Transform3D = interactor.held.get_grip_transform("chest")
		_present("carry", grip.origin, -camera.global_basis.z)
		return
	if _action.is_empty():
		_clear_hold_pose(); _unclaim(); return
	if not is_instance_valid(_target) or not _target.is_inside_tree() or camera.global_position.distance_to(_point) > TOUCH_REACH + .3:
		_finish(); return
	_time += delta
	if _action == "boop": _watch_finger()
	if _action == "hoof_hold":
		var hoof: RefCounted = _target.get("hoof_hold")
		if hoof == null or not hoof.active(): _finish(); return
		var goal: Vector3 = camera.to_global(_hoof_anchor)
		if not _clear_to(goal): _finish(); return
		hoof.update(goal); _point = hoof.grip().origin
		_present("hoof_hold", _point, _normal)
		return
	if _action == "pet":
		var current := _select()
		if not _pressed or current.is_empty() or current.target != _target: _finish(); return
		_point = current.point; _normal = current.normal; _offer = current
		var pose: Dictionary = presentation()
		_present("pet", pose.point, _normal)
		if _used:
			var touch: Node = _target.get("touch_body")
			if is_instance_valid(touch): touch.desktop_pet(str(current.region))
		return
	# A boop ends when his arm is back at his side (desktop_anon.gd times it), not by snapping back.
	if _action == "boop":
		if not is_instance_valid(_avatar) or not _avatar.is_busy() or _time >= 2.5: _finish()
		return
	if (_used and _time >= .4) or _time >= 1.0: _finish()


func _action_contact(kind: String, _at: Vector3, _side: String) -> void:
	if kind != _action or _used or not _available() or not is_instance_valid(_target): return
	# A desktop boop always lands (dev 2026-10-14): her head turns to watch the finger come in,
	# so a fresh pick at contact time often found her cheek or nothing and the boop was lost.
	if kind == "boop":
		_used = true
		_target.boop()
		return
	var current := _select(kind == "slap")
	if current.is_empty() or current.target != _target: return
	if is_instance_valid(_avatar) and _avatar.hand_frame(_side).origin.distance_to(current.point) > .16: return
	_used = true; _point = current.point; _normal = current.normal
	if kind == "boop" and str(current.get("kind", "")) == "boop": _target.boop()
	elif kind == "slap": current.flank.desktop_impact(current)


func pony_acquired() -> void:
	_claim()


func pony_released() -> void:
	_clear_hold_pose(); _unclaim()


func presentation() -> Dictionary:
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		var pony: Node3D = interactor.held
		var grip: Transform3D = pony.get_grip_transform("chest")
		return {"action": "carry", "target": pony, "point": grip.origin, "normal": -camera.global_basis.z,
			"helper": true, "progress": 1.0, "held": pony}
	if _action.is_empty() or not is_instance_valid(_target): return {}
	var point := _point
	if _action == "pet":
		# A held click produces an ordinary small stroke along the selected surface.
		var tangent := camera.global_basis.x - _normal * camera.global_basis.x.dot(_normal)
		if tangent.length_squared() > .001:
			point += tangent.normalized() * sin(maxf(0.0, _time-CONTACT_SECONDS)*TAU/STROKE_SECONDS) * .025
	return {"action": _action, "target": _target, "point": point, "normal": _normal,
		"helper": false, "progress": clampf(_time/CONTACT_SECONDS, 0.0, 1.0), "held": null}


func interaction_hint() -> Dictionary:
	if not _available(): return {}
	if is_instance_valid(interactor) and is_instance_valid(interactor.held) and interactor.cradled: return {}
	if is_instance_valid(interactor) and is_instance_valid(interactor.held):
		# "Tap"/"key" keep a bare B from reading as the VR B button icon.
		var key: String = Settings.key_label("carry_turn", "B")
		var turn := "Hold %s key · Carry normally" % key if interactor.cradled else "Tap %s · Turn around   Hold %s key · Bridal carry" % [key, key]
		if not interactor.cradled and interactor._cradle_carry() == null: turn = "Tap %s · Turn around" % key
		return {"target": interactor.held, "point": interactor.held.global_position,
			"text": "Tap G · Put down   Hold G, let go · Throw   %s   Hold K · Kiss" % turn, "outline": null, "visible_pick": true}
	if _action == "hoof_hold":
		return {"target": _target, "point": _point, "text": "E · Release hoof", "outline": null, "visible_pick": true}
	if not _social_free(): return {}
	var offer := _select()
	if offer.is_empty(): return {}
	var text := "Click · Boop" if offer.kind == "boop" else "Hold click · Stroke " + str(offer.region)
	var hoof: RefCounted = offer.target.get("hoof_hold")
	if hoof != null and not hoof.candidate(offer.point, .12).is_empty(): text += "   E · Hold hoof"
	if not _select(true).is_empty(): text += "   Right click · Smack"
	text += "   G · Carry   Hold G · Bridal carry"
	offer.text = text; offer.outline = null
	return offer


func _update_cradle_controls(delta: float) -> void:
	var on: bool = _available() and is_instance_valid(interactor) and is_instance_valid(interactor.held) and interactor.cradled
	if not on and not is_instance_valid(_cradle_controls): return
	if not is_instance_valid(_cradle_controls):
		_cradle_controls = preload("res://player/cradle_controls.gd").new()
		add_child(_cradle_controls)
	# Which rows apply changes with what is in front of him; checked a few times a second.
	_cradle_rows_in -= delta
	if on and _cradle_rows_in <= 0.0:
		_cradle_rows_in = .2
		var rest: Node = interactor.held.get_node_or_null("CradleRest")
		var bed: bool = rest != null and not rest.bed_spot(camera.global_position, -camera.global_basis.z).is_empty()
		_cradle_rows = [["G", "tap", "Lay in bed" if bed else "Put down"], ["G", "hold", "Throw"],
			["K", "hold", "Kiss"], [Settings.key_label("carry_turn", "B"), "hold", "Carry normally"]]
		if interactor.door_past_held() != null: _cradle_rows.insert(0, ["E", "", "Open door"])
	_cradle_controls.update(on, _cradle_rows, delta)


## While a boop comes in, her eyes follow his fingertip to her nose (dev 2026-10-14). Her own
## attention does the looking (action gaze), so near her nose her eyes cross onto the finger.
var _finger: Node3D

func _watch_finger() -> void:
	if not is_instance_valid(_avatar) or not is_instance_valid(_target) or not _target.has_method("set_action_gaze"): return
	var tip: Vector3 = _avatar.fingertip(str(_avatar.get("active_side")))
	if not tip.is_finite(): return
	if not is_instance_valid(_finger):
		_finger = Node3D.new(); _finger.name = "BoopFinger"; _finger.set_meta("boop_finger", true); add_child(_finger)
	_finger.global_position = tip
	if _target.get("action_gaze_target") != _finger: _target.set_action_gaze(_finger)
	# The finger goes to her nose where it is now, and after contact pushes it in a little
	# (dev 2026-10-29).
	var boop: Node = _target.get("boop_node")
	if not is_instance_valid(boop): return
	var nose: Vector3 = boop.nose_world()
	if _used and tip.distance_to(nose + boop.press_offset) < .02:
		boop.press(Vector3(nose.x - camera.global_position.x, 0.0, nose.z - camera.global_position.z))
	_avatar.update_action_target("boop", nose + boop.press_offset)

func _finish() -> void:
	if is_instance_valid(_target) and is_instance_valid(_finger) and _target.get("action_gaze_target") == _finger:
		_target.set_action_gaze(null)
	if is_instance_valid(_target):
		var touch: Node = _target.get("touch_body")
		if is_instance_valid(touch): touch.desktop_pet_end()
		if _action == "hoof_hold" and _target.get("hoof_hold") != null: _target.hoof_hold.release()
	if not _action.is_empty() and is_instance_valid(_avatar): _avatar.cancel_action()
	_clear_hold_pose()
	_action = ""; _target = null; _offer = {}; _pressed = false
	_unclaim()


func _clear_hold_pose() -> void:
	if _held_pose and is_instance_valid(_avatar):
		_avatar.clear_hold_target("right"); _avatar.clear_hold_target("left")
	_held_pose = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT: cancel_desktop_activity()


func _exit_tree() -> void:
	_finish()
	if is_instance_valid(interactor) and is_instance_valid(interactor.held): interactor._drop()
