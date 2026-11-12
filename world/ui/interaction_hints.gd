extends Node3D
const CURRENCY := preload("res://world/ui/currency.gd")
## Read-only affordances: input adapters retain selection, reach and action ownership.
## Providers in interaction_hint_sources return {target: Node3D, text: String} or {}; they may add
## "outline": Node3D (what glows, default the target) and "point" (where the prompt sits).
##
## The look (dev 2026-09-30): the thing you can use gets a blue cel outline
## (world/ui/interact_outline.gd) instead of the old dotted box, and the prompt is a row of
## cartoon controller buttons with a word or two ("[Grip] Pick up"), beside the object in VR and
## under the crosshair on desktop. In VR each free hand also outlines the item it would pick up
## (world/inventory/grab_targets.gd, the same pick the grip makes) with a small haptic tick.
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const INTERACTOR = preload("res://player/interactor.gd")
const GRAB := preload("res://world/inventory/grab_targets.gd")
const OUTLINE := preload("res://world/ui/interact_outline.gd")
const FOOD_CATALOG := preload("res://world/food/food_catalog.gd")
const SHOP_ITEMS := preload("res://world/shop/shop_items.gd")
const MARKET := preload("res://world/mechanics/market/market.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const DESKTOP_OWNER := preload("res://player/desktop_action_owner.gd")
const ICON_PATH := "res://world/ui/prompts/%s.png"
## Prompt icon edge in metres at one metre from the eye (VR); it scales with distance.
const ICON_M := 0.06
const FADE_SECONDS := 0.12
const SELECTION_INTERVAL := 0.08
var game: Node
var inventory: Node
var camera: Camera3D
var body: Node3D
var xr := false
var interactor: Node
var door_grip: Node
var _target: Node3D
var _point := Vector3.ZERO
var _elapsed := SELECTION_INTERVAL
var _text := ""
var _prompt3d: Node3D
var _prompt2d: HBoxContainer
var _crosshair: Control
var _layer: CanvasLayer
var _icons: Dictionary = {}
## GeometryInstance3D -> current outline amount; meshes fade in/out toward _wanted.
var _outlined: Dictionary = {}
var _wanted: Dictionary = {}
var _hand_items: Dictionary = {}
var _flight: RefCounted
var _flight3d: Label3D
var _flight2d: Label
## Labs only (tools/interaction/hint_shots.gd): show hints without capturing the mouse.
var force_available := false

func setup(host: Node, ui: Node) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	game = host; inventory = ui; camera = ui.camera; body = ui.player_body
	xr = not bool(ui._desktop)
	for child: Node in camera.get_children():
		if child.get_script() == INTERACTOR: interactor = child; break
	door_grip = game.get_node_or_null("DoorGrip")
	_prompt3d = Node3D.new(); _prompt3d.name = "Prompt"; add_child(_prompt3d)
	_layer = CanvasLayer.new(); _layer.layer = 5; add_child(_layer)
	if not xr:
		_crosshair = preload("res://world/ui/desktop_crosshair.gd").new()
		_layer.add_child(_crosshair)
		_crosshair.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_crosshair.hide()
	if "wing_flight" in body:
		_flight = body.wing_flight
		_flight3d = Label3D.new(); _flight3d.position = Vector3(0, -0.35, -1.5)
		_flight3d.font_size = 36; _flight3d.pixel_size = 0.00065; _flight3d.no_depth_test = true
		_flight3d.outline_size = 8; camera.add_child(_flight3d); _flight3d.hide()
		_flight2d = Label.new(); _layer.add_child(_flight2d)
		_flight2d.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
		_flight2d.offset_left = -500; _flight2d.offset_right = 500; _flight2d.offset_top = -100; _flight2d.offset_bottom = -50
		_flight2d.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_flight2d.add_theme_font_size_override("font_size", 24); _flight2d.add_theme_constant_override("outline_size", 8)
		_flight2d.mouse_filter = Control.MOUSE_FILTER_IGNORE; _flight2d.hide()
		_flight2d.add_to_group("caption_clearance")
	var anchor := CenterContainer.new()
	anchor.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	anchor.offset_top = -190; anchor.offset_bottom = -120; anchor.offset_left = -400; anchor.offset_right = 400
	anchor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(anchor)
	_prompt2d = HBoxContainer.new(); _prompt2d.add_theme_constant_override("separation", 10)
	_prompt2d.mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor.add_child(_prompt2d)
	# Pony speech captions sit above the prompt row while it shows (world/ui/speech_caption.gd).
	_prompt2d.add_to_group("caption_clearance")
	_hide_prompt()
	process_physics_priority = 20

func _icon(name: String) -> Texture2D:
	if not _icons.has(name):
		var path := ICON_PATH % name
		_icons[name] = load(path) if ResourceLoader.exists(path) else null
	return _icons[name]

func _available() -> bool:
	if not is_instance_valid(body) or not is_instance_valid(camera) or not is_instance_valid(inventory): return false
	if get_tree().paused: return false
	var owner: Node = DESKTOP_OWNER.current(inventory) if not xr else null
	if body.get("controls_locked") == true:
		if owner == null or not owner.has_method("owns_control_lock") or not owner.owns_control_lock(): return false
		var own_hint: Dictionary = owner.interaction_hint() if owner.has_method("interaction_hint") else {}
		if own_hint.is_empty() or not is_instance_valid(own_hint.get("target")): return false
	if xr and is_instance_valid(interactor) and is_instance_valid(interactor.get("held")): return false
	for key: String in ["save_menu", "settings_menu", "pause_menu"]:
		var panel: Node = game.get(key) as Node
		if is_instance_valid(panel) and panel.get("opened") == true: return false
	if inventory._map_open(): return false
	if is_instance_valid(inventory.case) and inventory.case.visible: return false
	if is_instance_valid(inventory.customizer) and inventory.customizer.get("opened") == true: return false
	if is_instance_valid(inventory.inspector) and inventory.inspector.get("active") == true: return false
	var focus: Control = get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit: return false
	return xr or force_available or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED

func _free(side: String) -> bool:
	if inventory.hand_busy(side): return false
	var hand: Node = inventory.hands.get(side)
	if is_instance_valid(hand) and hand.get_meta("pony_inspection", false): return false
	return not (is_instance_valid(interactor) and is_instance_valid(interactor.get("held")))

func _physics_process(delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	_fade(delta)
	if started > 0: CPU_PROFILE.record("interaction_hints", started)

func _physics_step(delta: float) -> void:
	var available := _available()
	if is_instance_valid(_crosshair): _crosshair.visible = available
	if not available:
		_clear(); return
	_elapsed += delta
	# Selection is presentation only; input adapters still pick on the actual action.
	if _elapsed < SELECTION_INTERVAL:
		if visible and is_instance_valid(_target): _place()
		return
	_elapsed = 0.0
	_hide_flight()
	_wanted.clear()
	if xr: _focus_hands()
	# Seated pony controllers keep keyboard inventory mode, but share this outline writer.
	for offer: Dictionary in _magic_offers():
		var glow: Node3D = offer.get("outline", offer.get("target")) as Node3D
		if glow != null: _want(glow)
	var hint: Dictionary = selection()
	var target: Node3D = hint.get("target") as Node3D
	if not is_instance_valid(target) or not target.is_inside_tree() or not target.is_visible_in_tree():
		_target = null; _hide_prompt(); _show_flight(); return
	var point: Vector3 = hint.get("point", target.global_position)
	if camera.global_position.distance_to(point) > 3.5 or (not bool(hint.get("visible_pick", false)) and not _visible_target(target, hint.get("collider"), point)):
		_target = null; _hide_prompt(); return
	var glow: Variant = hint.get("outline", target)
	if glow is Node3D: _want(glow)
	_target = target; _point = point
	var text := str(hint.get("text", ""))
	if text.is_empty(): _hide_prompt(); return
	if text != _text: _build_prompt(text)
	_place(); show()

## VR: each free hand outlines what its grip would take right now, with a light tick on change.
func _focus_hands() -> void:
	for side: String in ["left", "right"]:
		var target: Node3D = null
		var router: Node = inventory.get("grab_router")
		if router != null:
			var offered: Dictionary = router.offer(side)
			target = offered.get("outline", offered.get("target")) as Node3D
			if target != null: _want(target)
			_hand_items[side] = offered.get("target")
			continue
		var sample: Dictionary = inventory.hand_sample(side)
		if sample.get("active", false) and _free(side) and sample.has("pose") and (not is_instance_valid(door_grip) or door_grip.grip_offer(side) == null):
			var pose: Transform3D = sample.pose
			if pose.origin.is_finite():
				var pick: Dictionary = GRAB.pick(inventory, pose, sample.get("aim", pose))
				if not pick.is_empty(): target = pick.target
		if target != null: _want(target)
		var previous: Variant = _hand_items.get(side)
		if target != null and (not is_instance_valid(previous) or previous != target):
			var c: Node = inventory.controllers.get(side)
			if c is XRController3D and c.get_is_active(): c.trigger_haptic_pulse("haptic", 0.0, 0.08, 0.015, 0.0)
		_hand_items[side] = target

func _want(target: Node3D) -> void:
	for mesh: GeometryInstance3D in OUTLINE.meshes(target): _wanted[mesh] = true

func _fade(delta: float) -> void:
	for mesh: Variant in _wanted.keys():
		if is_instance_valid(mesh) and not _outlined.has(mesh): _outlined[mesh] = 0.0
	for mesh: Variant in _outlined.keys():
		if not is_instance_valid(mesh): _outlined.erase(mesh); continue
		var goal := 1.0 if _wanted.has(mesh) else 0.0
		var previous := float(_outlined[mesh])
		var amount := move_toward(previous, goal, delta / FADE_SECONDS) if xr else goal
		# Perf 0.1.0: a held outline is not rewritten every tick (same overlay, same amount);
		# it is still re-applied if anything else replaced the overlay meanwhile.
		if amount != previous or amount <= 0.0 or (mesh as GeometryInstance3D).material_overlay != OUTLINE.material():
			OUTLINE.set_amount(mesh, amount)
		if amount <= 0.0: _outlined.erase(mesh)
		else: _outlined[mesh] = amount

func _clear() -> void:
	# A menu/lock ending gets a fresh hint on the very next tick.
	_elapsed = SELECTION_INTERVAL
	_hide_flight()
	_wanted.clear(); _target = null; _hand_items.clear(); _hide_prompt()

func _hide_flight() -> void:
	if is_instance_valid(_flight3d): _flight3d.hide()
	if is_instance_valid(_flight2d): _flight2d.hide()

func _show_flight() -> void:
	if _flight == null or (not _flight.active and _flight.charge >= _flight.CAPACITY): return
	var words := "Wing stamina %d/8" % int(floor(_flight.charge))
	if _flight.landing: words += " · Landing"
	elif _flight.active:
		words += " · Hold A: flap · B: land" if xr else " · Space: flap · Release: glide · S: brake · LMB/RMB: bank · F: land"
	else: words += " · Recovering"
	if xr:
		if _flight3d.text != words: _flight3d.text = words
		_flight3d.show()
	else:
		if _flight2d.text != words: _flight2d.text = words
		_flight2d.show()

func _exit_tree() -> void:
	if is_instance_valid(_flight3d): _flight3d.queue_free()

func _hide_prompt() -> void:
	hide(); _prompt2d.get_parent().visible = false; _text = ""

## Same selection inputs as the real adapters; never calls take/sit/toggle/open.
func selection() -> Dictionary:
	if not xr:
		var owner: Node = DESKTOP_OWNER.current(inventory)
		if owner != null:
			return owner.interaction_hint() if owner.has_method("interaction_hint") else {}
	var magic: Array[Dictionary] = _magic_offers()
	if not magic.is_empty():
		var hint: Dictionary = magic[0].duplicate()
		hint["visible_pick"] = true
		return hint
	if xr and inventory.get("grab_router") != null:
		for side: String in ["right", "left"]:
			var offer: Dictionary = inventory.grab_router.offer(side)
			if offer.is_empty(): continue
			if offer.get("provider") == inventory:
				var hint := _item_hint(offer.target,"Grip",offer.target.global_position)
				hint.visible_pick = true
				return hint
			var hint: Dictionary = offer.duplicate()
			hint.visible_pick = true
			return hint
	# An adapter may offer a release/place action for its own busy hand.
	for source: Node in get_tree().get_nodes_in_group("interaction_hint_sources"):
		if not source.has_method("interaction_hint"): continue
		var offered: Variant = source.interaction_hint()
		if offered is Dictionary and is_instance_valid(offered.get("target")):
			return offered
	var seated: Node3D = body.get("seat") as Node3D
	if is_instance_valid(seated):
		var rest_hint := _rest_hint(seated)
		if not rest_hint.is_empty(): return rest_hint
		return {"target":_seat_target(seated), "text":"B · Stand" if xr else "E · Stand", "point":seated.global_position + Vector3.UP * .12}
	if body.get("flying") == true: return {}
	# AnonPony sitting or lying on the ground (Z / X): how to get up.
	var pony_form: Node = get_tree().get_first_node_in_group("player_pony_form")
	if not xr and pony_form != null and pony_form.has_method("ground_posture") and not str(pony_form.ground_posture()).is_empty():
		var avatar: Variant = pony_form.get("avatar")
		if avatar is Node3D:
			# Straight ahead at eye level: looking down while sitting, a point below the view lay in
			# the grass and failed the line-of-sight test.
			var flat := -camera.global_basis.z; flat.y = 0.0
			var ahead: Vector3 = camera.global_position + (flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD) * 1.2 - Vector3.UP * 0.15
			return {"target": avatar, "text": "Q · Get up", "point": ahead, "outline": null}
	var furnishing_hint: Dictionary = preload("res://world/housing/home_furnishing.gd").hint(inventory)
	if not furnishing_hint.is_empty(): return furnishing_hint
	var cooking_hint: Dictionary = preload("res://world/cooking/cooking_input.gd").hint(inventory)
	if not cooking_hint.is_empty(): return cooking_hint
	# Mechanics stations (world/mechanics/stations/station_input.gd): press, plot, stand tap.
	var station_hint: Dictionary = preload("res://world/mechanics/stations/station_input.gd").hint(inventory)
	if not station_hint.is_empty(): return station_hint
	for side: String in (["right", "left"] if xr else ["desktop"]):
		var slot: Node3D = inventory.shelf_offer(side) if inventory.has_method("shelf_offer") else null
		if slot != null:
			var book: Node3D = inventory.held[side]
			return {"target": book, "text": "Grip · Shelve book" if xr else "[E] Shelve book", "point": slot.global_position, "outline": null, "visible_pick": true}
	if xr:
		for side: String in ["right", "left"]:
			var item: Variant = _hand_items.get(side)
			if inventory.get("grab_router") == null and is_instance_valid(item): return _item_hint(item, "Grip", (item as Node3D).global_position)
		for side: String in ["right", "left"]:
			var sample: Dictionary = inventory.hand_sample(side)
			# DoorGrip owns the offer, including recovery, ownership and equipped-item transfer.
			if inventory.get("grab_router") == null and is_instance_valid(door_grip):
				var door: Node3D = door_grip.grip_offer(side)
				if door != null:
					var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
					var point: Vector3 = sample.get("grip_position", pose.origin)
					var door_hint := _door_hint(door, point, "Grip · Open")
					if not door_hint.is_empty(): door_hint.outline = null
					return door_hint
			if not sample.get("active", false) or not _free(side): continue
			var aim: Transform3D = sample.get("aim", Transform3D.IDENTITY)
			if not sample.has("aim") or not aim.is_finite(): continue
			if side == "right":
				var hit := _ray(aim.origin, aim.origin - aim.basis.z * 2.5, 1)
				var seat_hint := _seat_hint(hit, .9, "Trigger · Sit")
				if not seat_hint.is_empty(): return seat_hint
		return {}
	var look: Dictionary = inventory.desktop_look_target() if inventory.has_method("desktop_look_target") else {}
	# Holding one thing and looking at another: E puts the held one away and takes it
	# (briefcase_inventory.gd swap_take).
	var swap: bool = inventory.has_method("can_swap_take") and inventory.can_swap_take(look)
	if not _free("desktop") and not swap: return _held_hint()
	if not look.is_empty() and is_instance_valid(look.get("target")):
		var picked := _item_hint(look.target, "[E]", look.get("point", (look.target as Node3D).global_position))
		# The pickup ray already checked visibility, including this shelf's own collision box.
		# A second generic wall test incorrectly hid the highlight on usable shelf books.
		picked.visible_pick = true
		return picked
	if not is_instance_valid(interactor): return _held_hint()
	var ray: RayCast3D = interactor.get("_ray") as RayCast3D
	if not is_instance_valid(ray) or not ray.is_colliding(): return _held_hint()
	var hit := {"position":ray.get_collision_point(), "collider":ray.get_collider()}
	var seat_hint := _seat_hint(hit, 1.0, "[E] Sit")
	if not seat_hint.is_empty(): return seat_hint
	var collider: Node3D = hit.collider as Node3D
	if collider != null and collider.has_method("toggle_door"):
		var shut: bool = collider.has_method("knock_from_desktop") and float(collider.call("opening_angle")) <= 0.02
		return _door_hint(collider, camera.global_position, "[E] Open / close   [Right click] Knock" if shut else "[E] Open / close")
	return _held_hint()


func _magic_offers() -> Array[Dictionary]:
	var offers: Array[Dictionary] = []
	for source: Node in get_tree().get_nodes_in_group("magic_grab_sources"):
		if source.has_method("grab_offers"): offers.append_array(source.call("grab_offers"))
	return offers

## Desktop, holding something with nothing else in view: what a click does with it, and Q.
func _held_hint() -> Dictionary:
	var item: Variant = inventory.held.get("desktop") if inventory.get("held") is Dictionary else null
	if not is_instance_valid(item): return {}
	var id := str((item as Node).get_meta("item_id", ""))
	var use := ""
	# AnonPony wears no clothes (briefcase_inventory.gd held_usable): for her an outfit is only carried.
	if id == "spray-bottle": use = "Spray"
	elif (item as Node).get_node_or_null("BookItem") != null: use = "Read"
	elif SHOP_ITEMS.kind(id) in ["outfit", "equipment"] and not PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())): use = "Put on / take off" if id == "equipment:wing-sandals" else "Wear"
	elif inventory.has_method("held_usable") and inventory.held_usable(item):
		use = "Drink" if FOOD_CATALOG.has(id) and bool(FOOD_CATALOG.definition(id).get("drink", false)) else "Eat"
	var text := ("Click · %s   " % use if use != "" else "") + "Q · Throw"
	if inventory.has_method("desktop_place_offer") and not inventory.desktop_place_offer().is_empty(): text += "   Shift+Q · Place"
	return {"target": item, "text": text, "point": (item as Node3D).global_position, "outline": null}

## "Pick up", "Take book" or "Buy · 10 bits" for the thing a hand or the crosshair is on.
func _item_hint(item: Node3D, control: String, point: Vector3) -> Dictionary:
	var word := "Pick up"
	if item.is_in_group("banana_boxes"): word = "Take banana"
	elif item.has_meta("shelf_book"): word = "Take book"
	elif item.is_in_group("world_food") and bool(item.get_meta("food_for_sale", false)):
		var price := FOOD_CATALOG.price_bits(str(item.get_meta("item_id", "")))
		# A keeper's live [sell] offer (world/mechanics/market/market.gd) is the price shown.
		var stall: Variant = item.get_parent().get("display_id") if is_instance_valid(item.get_parent()) else null
		if price > 0 and stall is String: price = MARKET.live_price(item, str(stall), str(item.get_meta("item_id", "")), price)
		word = "Buy · " + CURRENCY.amount(price) + "\nBalance " + CURRENCY.amount(inventory.inventory.bits) if price > 0 else "Take"
	elif item.is_in_group("shop_items"):
		var shelf: Variant = item.get_meta("shop_display") if item.has_meta("shop_display") else null
		var good := str(item.get_meta("item_id", ""))
		var cost := SHOP_ITEMS.price_bits(good)
		if is_instance_valid(shelf) and (shelf as Node).get("display_id") is String: cost = MARKET.live_price(item, str((shelf as Node).get("display_id")), good, cost)
		word = "Buy · " + CURRENCY.amount(cost) + "\nBalance " + CURRENCY.amount(inventory.inventory.bits)
	var sep := " " if control.begins_with("[") else " · "
	if not xr and control == "[E]":
		return {"target": item, "text": "Click · " + word + "   E · Store", "point": point, "collider": item}
	return {"target": item, "text": control + sep + word, "point": point, "collider": item}

func _seat_hint(hit: Dictionary, radius: float, text: String) -> Dictionary:
	if hit.is_empty() or hit.collider is CharacterBody3D: return {}
	var seating: Node = get_tree().get_first_node_in_group("pony_seating")
	if seating == null: return {}
	# Main's collider-aware helper rejects unrelated surfaces and blocked seats.
	var seat: Node3D = seating.player_seat_near(hit.position, radius, body, hit.collider)
	var reach_from: Vector3 = camera.global_position if xr else body.global_position
	if seat == null or reach_from.distance_to(seat.global_position) > 3.0: return {}
	return {"target":_seat_target(seat), "text":text, "collider":hit.collider, "point":hit.position}

func _seat_target(seat: Node3D) -> Node3D:
	var furniture: Node3D = seat.get_parent() as Node3D
	# Interior chairs keep the artwork beside their Seating collision frame.
	# Only promote that known frame to a plausible single furniture model.
	if furniture.name == "Seating" and furniture.get_parent() is Node3D:
		var model: Node3D = furniture.get_parent() as Node3D
		var box: AABB = bounds_for(model)
		var size: Vector3 = box.size * model.global_basis.get_scale().abs()
		if size.x <= 4.5 and size.z <= 4.5 and size.y <= 3.0 and model.to_global(box.get_center()).distance_to(seat.global_position) <= 2.5:
			return model
	return furniture

func _door_hint(door: Node3D, from: Vector3, text: String) -> Dictionary:
	if not door.has_method("grip_point") or is_instance_valid(door.get("holder")): return {}
	var nearest: Node3D
	var gap := INF
	for key: String in ["OutsidePullCollision", "InsidePullCollision"]:
		var pull: Node3D = door.get_node_or_null(key) as Node3D
		if pull != null and pull.global_position.distance_to(from) < gap:
			nearest = pull; gap = pull.global_position.distance_to(from)
	if nearest == null: return {}
	return {"target":nearest, "text":text, "point":door.grip_point(from), "collider":door, "outline":door.get_node_or_null("PullHandles")}

func _rest_hint(seat: Node3D) -> Dictionary:
	var couch: Node3D = seat.get_meta("couch") as Node3D if seat.has_meta("couch") else null
	if couch == null: return {}
	var side := "right" if xr else "desktop"
	if not _free(side): return {}
	# AnonPony lies down with her own posture (player/pony_form.gd), not the human couch rest.
	var form: Node = get_tree().get_first_node_in_group("player_pony_form")
	var sleeping: bool = body.get_meta("couch_sleeping", false) or (form != null and form.has_method("is_lying") and form.call("is_lying") == true)
	if not sleeping and not couch.opened and not couch.can_open(): return {}
	var avatar: Node = body.get_parent().find_child("AnonBody", true, false) if xr else body.find_child("AnonBody", true, false)
	# The sofa's own measure (couch.gd anon_fits, as couch.begin_player asks); beds and grass naps
	# without one keep the old 1.3 cut (W1-LIFE-BEDS hook note).
	if not sleeping and is_instance_valid(avatar):
		var scale := float(avatar.get("model_scale"))
		if not (bool(couch.call("anon_fits", scale)) if couch.has_method("anon_fits") else scale <= 1.3): return {}
	var target: Node3D = _seat_target(seat)
	var point: Vector3 = seat.global_position + Vector3.UP * .03
	if xr:
		var sample: Dictionary = inventory.hand_sample("right")
		if not sample.get("active", false) or not sample.has("aim"): return {}
		var aim: Transform3D = sample.aim
		if not aim.is_finite(): return {}
		var local: Vector3 = couch.to_local(aim.origin)
		if absf(local.x) > .85 or local.z < -.12 or local.z > .65 or absf(local.y - .42) > .3: return {}
		point = aim.origin
	var text: String = ("Trigger" if xr else "[Ctrl]") + (" · Sit up" if sleeping else " · Lie down")
	if sleeping: text += ("   Stick · Shift   B · Get up   Hold A · Sleep" if xr else "   WASD · Shift   Q · Get up   Hold Space · Sleep")
	# Resting on a bed: the whole bed would light up; the prompt alone is enough there.
	return {"target":target, "text":text, "point":point, "outline":null}

func _ray(from: Vector3, to: Vector3, mask: int) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, mask)
	if body is CollisionObject3D: query.exclude = [body.get_rid()]
	return get_world_3d().direct_space_state.intersect_ray(query)

func _visible_target(target: Node3D, collider: Node, point: Vector3) -> bool:
	if camera.is_position_behind(point): return false
	var hit := _ray(camera.global_position, point, 1)
	if hit.is_empty(): return true
	var obstruction: Node = hit.collider as Node
	return obstruction == collider or obstruction == target or target.is_ancestor_of(obstruction)

static func bounds_for(target: Node3D) -> AABB:
	var boxes: Array[AABB] = []
	_collect_bounds(target, target.global_transform.affine_inverse(), boxes, false)
	_collect_bounds(target, target.global_transform.affine_inverse(), boxes, true)
	if boxes.is_empty(): return AABB()
	var result: AABB = boxes[0]
	for box: AABB in boxes: result = result.merge(box)
	return result.grow(.012)

static func _collect_bounds(node: Node, inverse: Transform3D, boxes: Array[AABB], collisions: bool) -> void:
	if node is Node3D and not node.is_visible_in_tree(): return
	if not collisions and node is MeshInstance3D and node.mesh != null:
		boxes.append(inverse * node.global_transform * node.get_aabb())
	elif collisions and node is CollisionShape3D and node.shape != null and not node.disabled:
		boxes.append(inverse * node.global_transform * node.shape.get_debug_mesh().get_aabb())
	for child: Node in node.get_children(): _collect_bounds(child, inverse, boxes, collisions)

## Hint text -> [{icons: [names], text: String}]. Segments are separated by three spaces or " | ";
## each is "<control> · <words>" or "[KEY] <words>". Unknown controls keep their words.
## Every segment reads the same way, control first, then "Hold: words" (thread 43671981: the
## carry row printed "Tap G · Put down Hold G, let go · Throw" as raw text beside icon rows).
## A keyboard key with no drawn icon (G, K, B on desktop) becomes "cap:<KEY>", a drawn key cap.
## A status before the control ("Casting · [E/Q] Return rod", NEXT_STEPS C9) stays words, in a
## segment of its own, and the control after it gets its icons like any other.
static func parse(text: String) -> Array:
	var result: Array = []
	for raw: String in text.replace(" | ", "   ").split("   ", false):
		var part := raw.strip_edges()
		if part.is_empty(): continue
		var control := ""; var words := part
		if part.begins_with("["):
			var close := part.find("]")
			if close > 0: control = part.substr(1, close - 1); words = part.substr(close + 1).strip_edges().trim_prefix("· ")
		elif part.contains(" · "):
			control = part.get_slice(" · ", 0); words = part.substr(control.length() + 3).strip_edges()
		var icons := control_icons(control)
		# Keys the icon set lacks ("G", "Tap B", the G of "Shift+G") become key caps.
		if not control.is_empty():
			var caps := key_caps(control)
			if caps.size() > icons.size(): icons = caps
		if icons.is_empty() and not control.is_empty() and not part.begins_with("["):
			var after: Array = parse(words)
			if not after.is_empty() and not (after[0].icons as Array).is_empty():
				result.append({"icons": [], "text": control})
				result.append_array(after)
				continue
		var lower := control.to_lower()
		if icons.is_empty() and not control.is_empty(): words = part
		elif lower.begins_with("hold ") and lower.ends_with(", let go"): words = "Hold, let go: " + words
		elif lower.begins_with("hold "): words = "Hold: " + words
		elif lower.begins_with("release "): words = "Release: " + words
		result.append({"icons": icons, "text": words})
	return result

## Key caps ["cap:G"] for a keyboard control without an icon: "G", "Tap B", "Hold B key",
## "Hold G, let go", "F5", "Ctrl+G" (known keys keep their icons). [] when any part is words
## ("Aim at its basket"), so instructions stay plain text.
static func key_caps(control: String) -> Array:
	var c := control.strip_edges()
	for prefix: String in ["Tap ", "Press ", "Hold ", "Release "]:
		if c.begins_with(prefix): c = c.substr(prefix.length()); break
	c = c.trim_suffix(", let go").trim_suffix(" key").strip_edges()
	var caps: Array = []
	var key := RegEx.create_from_string("^([A-Z0-9]|F[0-9]{1,2}|Kp [0-9]|[A-Z][a-z]+[A-Z][a-z]*)$")
	for token: String in c.replace(" + ", "+").split("+", false):
		var t := token.strip_edges()
		var known := control_icons(t)
		# Keyboard icons only: a desktop "Tap B" is the B key, never the controller's B button.
		if known.size() == 1 and str(known[0]).begins_with("key_"): caps.append(known[0])
		elif key.search(t) != null: caps.append("cap:" + t)
		else: return []
	return caps

## Icon names (world/ui/prompts/<name>.png) for a control phrase like "Right grip", "B", "E/Q",
## "Grip + trigger", "LMB", "Ctrl".
static func control_icons(control: String) -> Array:
	var icons: Array = []
	var c := control.to_lower().replace("right click", "rmb").replace("left click", "lmb")
	c = c.replace("left ", "").replace("right ", "").replace("release ", "").replace("hold ", "").strip_edges()
	for token: String in c.replace(" + ", "/").replace("+", "/").replace(" and ", "/").split("/", false):
		var t := token.strip_edges()
		match t:
			"a", "b", "x", "y": icons.append("button_" + t)
			"grip", "grip and tilt", "grip and pull down": icons.append("grip")
			"trigger", "hold trigger": icons.append("trigger")
			"stick": icons.append("stick")
			"lmb", "left click", "click", "drag", "mouse": icons.append("mouse_left")
			"rmb", "right-click", "right click": icons.append("mouse_right")
			"e", "q", "f", "r", "c", "1", "2", "3", "4", "tab", "esc", "space", "ctrl", "shift", "enter", "wasd":
				icons.append("key_" + t)
	return icons

func _build_prompt(text: String) -> void:
	_text = text
	for child: Node in _prompt3d.get_children(): child.queue_free()
	for child: Node in _prompt2d.get_children(): child.queue_free()
	var x := 0.0
	var first := true
	for segment: Dictionary in parse(text):
		# A gap between segments, so "Put down" never runs into the next control.
		if not first:
			var gap := Control.new(); gap.custom_minimum_size = Vector2(18, 0); gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_prompt2d.add_child(gap)
		first = false
		for name: String in segment.icons:
			if name.begins_with("cap:"):
				x = _add_key_cap(name.substr(4), x); continue
			var texture := _icon(name)
			if texture == null: continue
			var sprite := Sprite3D.new(); sprite.texture = texture
			sprite.pixel_size = ICON_M / texture.get_width(); sprite.position = Vector3(x + ICON_M * .5, 0, 0)
			sprite.no_depth_test = true; sprite.render_priority = 10; sprite.shaded = false
			sprite.alpha_cut = SpriteBase3D.ALPHA_CUT_DISABLED
			_prompt3d.add_child(sprite); x += ICON_M * 1.05
			var rect := TextureRect.new(); rect.texture = texture
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE; rect.custom_minimum_size = Vector2(52, 52)
			rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED; rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_prompt2d.add_child(rect)
		var words := str(segment.text)
		if words.is_empty(): continue
		var label := Label3D.new(); label.text = words; CURRENCY.apply(label)
		label.font_size = 44; label.pixel_size = ICON_M / 72.0; label.outline_size = 12
		label.modulate = Color("f4f1ff"); label.outline_modulate = Color("1a1624")
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT; label.no_depth_test = true; label.render_priority = 10
		label.position = Vector3(x + ICON_M * .12, 0, 0)
		_prompt3d.add_child(label)
		var longest := 0
		for line: String in words.split("\n"): longest = maxi(longest, line.length())
		x += ICON_M * .24 + longest * ICON_M * .33 + ICON_M * .5
		var text_label := Label.new(); text_label.text = words; CURRENCY.apply(text_label)
		text_label.add_theme_font_size_override("font_size", 30)
		text_label.add_theme_color_override("font_color", Color("f4f1ff"))
		text_label.add_theme_color_override("font_outline_color", Color("1a1624"))
		text_label.add_theme_constant_override("outline_size", 10)
		text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_prompt2d.add_child(text_label)
	_prompt3d.set_meta("width", x)

## A dark key cap with the key in white, sized and placed like the drawn key icons
## (prompts/key_*.png), for keys that have no icon. Returns the next 3D x.
func _add_key_cap(key: String, x: float) -> float:
	var letters := Label3D.new(); letters.text = key; CURRENCY.apply(letters)
	letters.font_size = 40; letters.pixel_size = ICON_M / 72.0; letters.outline_size = 30
	letters.modulate = Color("f4f1ff"); letters.outline_modulate = Color("1f1d26")
	letters.no_depth_test = true; letters.render_priority = 10
	letters.position = Vector3(x + ICON_M * .5, 0, 0)
	_prompt3d.add_child(letters)
	var holder := CenterContainer.new(); holder.custom_minimum_size = Vector2(52, 52)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cap := PanelContainer.new(); cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color("1f1d26"); style.border_color = Color("9a97a8")
	style.set_border_width_all(2); style.border_width_bottom = 4
	style.set_corner_radius_all(9)
	style.content_margin_left = 8.0; style.content_margin_right = 8.0
	cap.add_theme_stylebox_override("panel", style)
	cap.custom_minimum_size = Vector2(42, 42)
	var text := Label.new(); text.text = key; CURRENCY.apply(text)
	text.add_theme_font_size_override("font_size", 26)
	text.add_theme_color_override("font_color", Color("f4f1ff"))
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cap.add_child(text); holder.add_child(cap)
	_prompt2d.add_child(holder)
	return x + ICON_M * maxf(1.05, .3 + key.length() * .33)

## VR: the row floats just above the target point, turned to face the eye, sized for distance.
## Desktop: the 2D row under the crosshair.
func _place() -> void:
	if not xr:
		_prompt3d.visible = false
		_prompt2d.get_parent().visible = _prompt2d.get_child_count() > 0
		return
	_prompt2d.get_parent().visible = false
	_prompt3d.visible = true
	var eye := camera.global_position
	var distance := maxf(0.25, eye.distance_to(_point))
	var scale := clampf(distance, 0.35, 2.5)
	var facing := Basis.looking_at(_point - eye, Vector3.UP)
	var width := float(_prompt3d.get_meta("width", 0.0)) * scale
	# Above the thing and a little toward the eye, so the row never runs across it (the larger
	# 6 cm icons of 2026-09-30 covered a burger from its centre up).
	var at := _point + facing.y * ((0.06 + ICON_M) * scale) + facing.z * (0.05 * scale) - facing.x * (width * 0.5)
	_prompt3d.global_transform = Transform3D(facing.scaled(Vector3.ONE * scale), at)
