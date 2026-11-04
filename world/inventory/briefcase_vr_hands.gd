extends RefCounted
## The VR per-hand step: grip and trigger edges, the forearm hotbar, lasers, bananas, books and stashing at the wrist.
## Split out of briefcase_inventory.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning briefcase_inventory node; shared state stays there.

const SFX := preload("res://world/audio/interaction_sounds.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const STATION_INPUT := preload("res://world/mechanics/stations/station_input.gd")
const BANANAS := preload("res://world/food/banana_boxes.gd")
const SHOP_ITEMS := preload("res://world/shop/shop_items.gd")
const HOTBAR := preload("res://world/inventory/wrist_hotbar.gd")

var host: Node3D


func _init(owner_node: Node3D) -> void:
	host = owner_node


## Grip presses only switch slots while aiming/touching the HUD or looking at it.
## Elsewhere grips retain their physical grabbing purpose. Hold no grip to keep equipment.
## Sample before menu/inspection early exits too. A HUD press belongs to the HUD until
## release, even if opening a menu or aiming elsewhere hides its original target.
func _sample_hud_trigger(side: String, sample: Dictionary) -> bool:
	if not sample.get("active", false):
		host._hud_trigger_pressed[side] = false; host._hud_trigger_claim[side] = false
		host._ray_pressed[side] = false
		return false
	var down := float(sample.trigger) > (.3 if host._hud_trigger_pressed[side] else .65)
	var pressed: bool = down and not host._hud_trigger_pressed[side]
	host._hud_trigger_pressed[side] = down
	if not down: host._hud_trigger_claim[side] = false
	return pressed


func _hotbar_input(side: String, sample: Dictionary, grip: bool, trigger_edge: Variant = null) -> bool:
	var trigger_pressed: bool = _sample_hud_trigger(side, sample) if trigger_edge == null else bool(trigger_edge)
	if host._hud_trigger_claim[side] and host._hud_trigger_pressed[side]:
		host._ray_pressed[side] = true; host._pressed[side] = grip
		return true
	if host._bar_grip_claim[side]:
		if not grip:
			host._bar_grip_claim[side] = false
			if not host.held.has(side): host._claim(side, false)
		else:
			host._pressed[side] = grip
			return not host.held.has(side)
	if not host.hotbar.visible or host.case.visible or host._map_open() or host.customizer.opened: return false
	if host.hand_busy(side) and not host.held.has(side): return false
	var pose: Transform3D = sample.pose
	var index: int = host.hotbar.slot_at(pose.origin, sample.tip)
	# A held object touching a slot is preparing a deposit. Do not replace it
	# with the slot's contents on squeeze; the release path commits the stash.
	if host.held.has(side) and index>=0 and index<HOTBAR.SLOTS:return false
	var aim: Transform3D = sample.get("aim", pose)
	if index < 0: index = host.hotbar.ray_slot(aim.origin, -aim.basis.z)
	if side == "right": host.hotbar.hover(index)
	if host._quick_open and index >= 0:
		if host._pointers.has(side):
			var normal: Vector3 = host.hotbar.global_basis.z.normalized()
			var facing: float = normal.dot(-aim.basis.z)
			if facing < -.001:
				var distance: float = normal.dot(host.hotbar.global_position - aim.origin) / facing
				host._pointers[side].aim(aim.origin, aim.origin - aim.basis.z * distance)
		if host._hud_trigger_pressed[side]:
			host._hud_trigger_claim[side] = true
			host._ray_pressed[side] = true; host._pressed[side] = grip
			if trigger_pressed: _activate_head_action(side, index, pose)
			return true
	if not grip or host._pressed[side]: return false
	if index in [HOTBAR.OPEN_MAP, HOTBAR.OPEN_APPEARANCE, HOTBAR.OPEN_PONIES]:
		_activate_head_action(side, index, pose)
		host._bar_grip_claim[side] = true; host._claim(side, true); host._pressed[side] = grip
		return true
	if index in [HOTBAR.OPEN_CASE, HOTBAR.EMPTY_HAND]:
		if index == HOTBAR.OPEN_CASE: host.summon(true)
		elif host.held.has(side): host._return_held(side)
		host._bar_grip_claim[side] = true; host._claim(side, true); host._pressed[side] = grip
		return true
	if float(sample.trigger) > .35: return false
	var target: String = side
	if index < 0:
		if host.hotbar.ray_slot(host.camera.global_position, -host.camera.global_basis.z) < 0: return false
		target = "right"
		if host.hand_busy(target) and not host.held.has(target): return false
		var current_slot: int = int(host._selected_slots[target])
		index = (HOTBAR.SLOTS - 1 if side == "left" else 0) if current_slot < 0 else posmod(current_slot + (-1 if side == "left" else 1), HOTBAR.SLOTS)
		pose = host.hand_sample(target).get("pose", pose)
	if _select_slot(target, index, pose):
		host._bar_grip_claim[side] = true
		host._claim(side, true)
	host._pressed[side] = grip
	return true


func _activate_head_action(side: String, index: int, pose: Transform3D) -> void:
	match index:
		HOTBAR.OPEN_CASE: host.summon(true)
		HOTBAR.EMPTY_HAND:
			if host.held.has(side): host._return_held(side)
		HOTBAR.OPEN_MAP:
			if is_instance_valid(host.map_menu):
				if host.map_menu.has_method("set_open"): host.map_menu.set_open(true)
				elif host.map_menu.has_method("set_expanded"): host.map_menu.set_expanded(true)
		HOTBAR.OPEN_APPEARANCE: host._open_clothes()
		HOTBAR.OPEN_PONIES:
			if is_instance_valid(host.inspector): host.inspector.toggle()
		_: _select_slot(side, index, pose)
	host._haptic(side)


func _select_slot(side: String, index: int, pose: Transform3D) -> bool:
	if index < 0 or index >= STORE.SLOT_COUNT or (host.hand_busy(side) and not host.held.has(side)): return false
	var previous: String = str(host.held[side].get_meta("token")) if host.held.has(side) else ""
	if not previous.is_empty() and host.inventory.loans.get(previous, {}).get("equipped", false) and int(host.inventory.loans[previous].slot) == index: return true
	var entry: Dictionary = host.inventory.slots[index]
	var visual: Node3D
	if not entry.is_empty():
		var scene: PackedScene = CATALOG.scene(str(entry.id))
		if scene == null: return false
		visual = scene.instantiate()
	var result: Dictionary = host.inventory.select_slot(index, previous)
	if result.is_empty():
		if host.inventory.last_error.is_empty(): host.inventory.last_error = "That item is in your other hand, or there is no room to put this one away."
		if visual != null: visual.free()
		host._error(); return false
	if host.held.has(side):
		var old: RigidBody3D = host.held[side]
		host._unglow(old)
		host.held.erase(side); host.loose.erase(previous); old.queue_free()
	host._track.erase(side); host._eat_time.erase(side)
	host._selected_slots[side] = index
	var token: String = result.token
	# Returning a loose item can fill the selected empty slot; load that visual now.
	if not token.is_empty():
		var id: String = host.inventory.loans[token].id
		if visual == null: visual = CATALOG.scene(id).instantiate()
		var item: RigidBody3D = host._make_item(token, id, visual)
		item.set_meta("hold_offset", host.hold_local(id)); item.set_meta("toggle_armed", false)
		item.global_transform = host._held_world(item, pose,host.hand_sample(side))
		host.loose[token] = item; host.held[side] = item
	elif visual != null: visual.free()
	host._claim(side, not token.is_empty()); host._refresh_holding(); host._haptic(side)
	host._selected_slots[side] = index
	host.hotbar.select(index); host.hotbar.set_message(""); host._play_select()
	return true


## One automatic portion when an empty palm enters an authored box opening. Recovery, menus,
## occupied hands and failed saves consume that entry; withdrawal must rearm it.
func _banana_entry(side: String, sample: Dictionary) -> bool:
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var palm: Vector3 = sample.get("grip_position", pose.origin)
	if host._desktop or not sample.get("active", false) or not pose.is_finite() or absf(pose.basis.determinant()) < .0001 or not palm.is_finite() or not BANANAS.allowed(host) or host._hud_trigger_claim.get(side, false):
		host._banana_armed[side] = false; host._banana_palm.erase(side); return false
	var previous: Vector3 = host._banana_palm.get(side, palm)
	var continuous: bool = host._banana_palm.has(side) and previous.distance_to(palm) <= .5
	host._banana_palm[side] = palm
	if not continuous: host._banana_armed[side] = false
	var box := BANANAS.containing(host.get_tree(), palm)
	if box == null:
		if BANANAS.containing(host.get_tree(), palm, .025) == null: host._banana_armed[side] = true
		return false
	var armed := bool(host._banana_armed.get(side, false))
	host._banana_armed[side] = false
	if not armed or not continuous or host.hand_busy(side) or not BANANAS.clear_path(box, previous, palm): return false
	return BANANAS.take(host, side, box, pose, palm)


func _update_hand_step(side: String, sample: Dictionary, _delta: float):
	_book_fingers(side)
	var cooking_pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	if not sample.get("active", false) or not cooking_pose.is_finite() or not COOKING.allowed(host):
		host._cooking_armed[side] = false
	elif float(sample.get("grip", 0.0)) < .35:
		host._cooking_armed[side] = true
	if _banana_entry(side, sample):
		host._pressed[side] = float(sample.get("grip", 0.0)) > .65
		return
	# A release over a stash surface wins before UI consumes input. This also
	# deliberately stashes toggle-held books/equipment without dropping them.
	if sample.get("active", false) and host.held.has(side) and host._pressed[side] and float(sample.get("grip", 0.0)) <= .25:
		var destination := _stash_target(side, sample)
		if not destination.is_empty():
			if not _store_at_wrist(host.held[side], destination.index, destination.point):
				# The player intended to store, not drop. Keep holding until the next
				# deliberate squeeze/release instead of dropping on the following tick.
				host.held[side].set_meta("stash_rejected",true)
			return
	var trigger_edge: bool = _sample_hud_trigger(side, sample)
	if host._pointers.has(side): host._pointers[side].hide()
	if host._hud_trigger_claim[side] and host._hud_trigger_pressed[side]:
		host._ray_pressed[side] = true
		host._pressed[side] = float(sample.grip) > (.25 if host._pressed[side] else .45)
		if host.held.has(side):
			var tracked_pose: Transform3D = sample.pose
			if tracked_pose.is_finite():
				host.held[side].global_transform = host._held_clear(host.held[side], host._held_world(host.held[side], tracked_pose,sample))
				host._track_item(side, host.held[side])
		return
	# Desktop inspection is driven by the mouse (pony_inspector._input). The absent right
	# controller must not reset its hover every tick: a click on a pony never selected her.
	if host.inspector!=null and host.inspector.active and side=="right" and not host._desktop:
		if sample.get("active",false) and host._wrist_input(side,sample):return
		host.inspector.update_hand(sample);return
	if host._pointers.has(side):host._pointers[side].hide()
	if not sample.get("active",false):
		if host._pointers.has(side):host._pointers[side].hide()
		host._ray_pressed[side]=false;host._hud_trigger_pressed[side]=false
		if host._bar_grip_claim[side]:
			host._bar_grip_claim[side]=false;host._claim(side,false)
		if side=="right":host._wrist_armed=false;host._wrist_tip=null
		if host.held.has(side):host._return_held(side)
		if host.holding_case==side:host._release_case()
		host._pressed[side]=false;host._poke_armed[side]=false;host._last_tip.erase(side);return
	var pose:Transform3D=sample.pose
	var tip:Vector3=sample.tip
	if not tip.is_finite() or not pose.origin.is_finite():return
	if host._last_tip.has(side) and tip.distance_to(host._last_tip[side])>.5:
		if side=="right":host._wrist_armed=false;host._wrist_tip=null
		if host.held.has(side):host._return_held(side)
		if host.holding_case==side:host._release_case()
		host._poke_armed[side]=false;host._last_tip[side]=tip;return
	host._last_tip[side]=tip
	if host.case.visible and host.case.amount>.95:
		var over:Vector3=host.case.panel_point(tip)
		var index:int=host.case.ui.slot_at(Vector2(over.x,over.y))
		if index>=0 and over.z>=-.025 and over.z<.12:
			if not host.held.has(side) or host.inventory.can_put(host.held[side].get_meta("token"),index):host._next_hover=index
	if not host.hand_busy(side) and host.customizer.opened:
		var point:Vector3=host.customizer.panel_point(tip)
		if point.z>.025:host._poke_armed[side]=true
		if host._poke_armed[side] and point.z<=.008 and point.z>=-.025 and float(sample.trigger)<.3:
			host._poke_armed[side]=false;host.customizer.activate(Vector2(point.x,point.y));host._haptic(side)
		return
	# A glowing world item owns this squeeze before passive hand-flip panels can
	# consume it (including the hotbar's head-gaze fallback on either hand).
	var world_grip: bool = float(sample.grip) > .65 and not host._pressed[side]
	if host.grab_router == null and world_grip and not host.hand_busy(side) and not host.customizer.opened:
		if host._take_nearby(side, pose, sample.get("aim", pose)):
			host._pressed[side] = true
			host._dismiss_quick_strip(); host.wrist.hide()
			return
	if (not host.hand_busy(side) or host.held.has(side)) and host._wrist_input(side,sample):
		if host.held.has(side):
			host.held[side].global_transform=host._held_clear(host.held[side],host._held_world(host.held[side],pose,sample))
			host._track_item(side,host.held[side])
		return
	var grip:=float(sample.grip)>.45 if not host._pressed[side] else float(sample.grip)>.25
	if _hotbar_input(side,sample,grip,trigger_edge): return
	if host._laser_input(side,sample):
		host._pressed[side]=grip
		return
	# Mechanics stations (station_input.gd): a free hand's grip goes to the nearest station node
	# (a crank, a slot); the node that took it hears the release.
	if not grip and STATION_INPUT.engaged(side): STATION_INPUT.offer(host, side, false)
	elif grip and not host._pressed[side] and not host.hand_busy(side) and STATION_INPUT.offer(host, side, true):
		host._pressed[side] = true; return
	if grip and not host._pressed[side] and host._cooking_armed[side] and not host.hand_busy(side):
		var cooking_offer: Dictionary = COOKING.offer(host, side)
		if cooking_offer.get("role", "") == "knob" and COOKING.activate(host, side):
			host._cooking_armed[side] = false; host._pressed[side] = true; return
	if side=="right" and host.hotbar.visible and host.hotbar.hover(host.hotbar.slot_at(pose.origin,tip)):host._haptic(side)
	if host.held.has(side):
		var item:RigidBody3D=host.held[side]
		item.global_transform=host._held_clear(item,host._held_world(item,pose,sample))
		host._track_item(side,item)
		if host._item_use.wearable(item) and float(sample.trigger) > .7 and not host._pressed.get(side+"_outfit",false):
			host.wear_outfit(item)
		host._pressed[side+"_outfit"] = float(sample.trigger) > .7
		if item.get_meta("item_id", "") == "goods:folded-blanket":
			var blanket_pull: bool = float(sample.trigger) > .7
			if blanket_pull and not host._pressed.get(side + "_blanket", false):
				host._pressed[side + "_blanket"] = true
				if host._lay_out_blanket(side): host._pressed[side] = grip; return
			host._pressed[side + "_blanket"] = blanket_pull
		if item.get_meta("item_id", "") == "goods:easel":
			var easel_pull: bool = float(sample.trigger) > .7
			if easel_pull and not host._pressed.get(side + "_easel", false):
				host._pressed[side + "_easel"] = true
				if load(host.EASEL_FOLD).unfold(host, side): host._pressed[side] = grip; return
			host._pressed[side + "_easel"] = easel_pull
		if item.get_meta("item_id", "") == "goods:camera":
			var photo_camera: Node3D = host.PHOTO_CAMERA.on(item)
			photo_camera.vr_tick(host.camera)
			var shutter: bool = float(sample.trigger) > .7
			if shutter and not host._pressed.get(side + "_shutter", false): photo_camera.snap(host, null)
			host._pressed[side + "_shutter"] = shutter
		# Paper and letters: trigger starts, opens, folds or reads; held a second it sends a draft
		# with Derpy. The quill writes by voice over open paper in the other hand (world/letters/paper/).
		if host.LETTER_TOOL.handles(item):
			host.LETTER_TOOL.on(item).vr_step(host, side, sample)
			if not is_instance_valid(item) or item.is_queued_for_deletion():
				host._pressed[side] = grip; return
		elif item.get_meta("item_id", "") == "goods:quill":
			host.QUILL_TOOL.on(item).vr_step(host, side)
		elif host.NOTEBOOK_TOOL.handles(item):
			# Anon's notebook: trigger opens its favour pages, turns them, closes it (world/mechanics/asks/).
			host.NOTEBOOK_TOOL.on(item).vr_step(host, side, sample)
		elif host.PHOTO_JOURNAL.handles(item):
			host.PHOTO_JOURNAL.on(item).vr_step(host, side, sample)
		elif host.FURNISHING.resizable(item):
			# A held print over a wall: the trigger steps through its sizes (home_furnishing.gd).
			var resize: bool = float(sample.trigger) > .7
			if resize and not host._pressed.get(side + "_resize", false): host.FURNISHING.step_size(host, side)
			host._pressed[side + "_resize"] = resize
		if item.get_meta("item_id", "") == "spray-bottle" and float(sample.trigger) > .7:
			item.get_node("SprayBottle").spray()
		if CATALOG.is_book(String(item.get_meta("item_id",""))):
			_book_hand(side,item,sample,pose)
		var mouth_near:bool=FOOD.mouth_near(item,host._mouth()) if FOOD.has(str(item.get_meta("item_id",""))) else item.global_position.distance_to(host._mouth())<.1
		if host._eat_tick(side,item,_delta,mouth_near):
			host._pressed[side]=grip;return
		if grip:
			item.remove_meta("ray_hold")
			item.remove_meta("stash_rejected")
		var let_go:bool=not grip and not item.has_meta("ray_hold") and not item.has_meta("stash_rejected")
		if host.inventory.loans.get(str(item.get_meta("token")), {}).get("equipped", false) or CATALOG.is_book(String(item.get_meta("item_id",""))) or CATALOG.is_letter(String(item.get_meta("item_id",""))) or host.NOTEBOOK_TOOL.handles(item):
			# dev 2026-09-26: books are held by toggle so the hand can rest while reading; letters
			# too (world/letters/), while reading or writing with the quill in the other hand.
			# Letting go of grip keeps the book; the next squeeze puts it down (or away).
			if not grip:item.set_meta("toggle_armed",true)
			let_go=grip and not host._pressed[side] and bool(item.get_meta("toggle_armed",false)) and _stash_target(side,sample).is_empty()
		if let_go:
			var p:Vector3=host.case.panel_point(tip)
			var index:int=host.case.ui.slot_at(Vector2(p.x,p.y))
			var quick:int=host.hotbar.slot_at(item.global_position,pose.origin)
			if quick>=HOTBAR.SLOTS:quick=-1
			if quick>=0 and host.inventory.can_put(item.get_meta("token"),quick):
				host._store_held(side,quick)
			elif host.case.visible and host.case.amount>.95 and absf(p.z)<.13 and index>=0 and host.inventory.can_put(item.get_meta("token"),index):
				host._store_held(side,index)
			elif host.case.visible and _over_tray(item.global_position):host._store_held(side)
			elif COOKING.activate(host, side): pass
			elif item.has_meta("world_pick"):host._release_to_world(side)
			else:host._drop(side)
	elif host.holding_case==side:
		host.case.global_transform=pose*host._case_offset
		if not grip:host._release_case()
	elif not host.hand_busy(side):
		if grip and not host._pressed[side]:
			if host.case.visible and pose.origin.distance_to(host.case.handle_world())<.11:
				host.holding_case=side;host._case_offset=pose.affine_inverse()*host.case.global_transform;host._claim(side,true);host._haptic(side)
			elif host.grab_router != null or not host._take_nearby(side,pose,sample.get("aim",pose)):
				var p:Vector3=host.case.panel_point(tip)
				if host.case.visible and host.case.amount>.95 and p.z>-.025 and p.z<.10:
					host.take_slot(side,host.case.ui.slot_at(Vector2(p.x,p.y)),pose)
		elif not grip and float(sample.trigger)<.3 and host.case.visible:
			if host.case.amount>.95:
				var p:Vector3=host.case.panel_point(tip)
				if p.z>.025:host._poke_armed[side]=true
				if host._poke_armed[side] and p.z<=.008 and p.z>=-.025:
					host._poke_armed[side]=false;host.activate(Vector2(p.x,p.y),side,pose);host._haptic(side)
			elif not host.case.opened:
				var opposite:Vector3=host.case.to_local(host.case.clasp_world());opposite.x=-opposite.x
				var distance:=minf(tip.distance_to(host.case.clasp_world()),tip.distance_to(host.case.to_global(opposite)))
				if distance>.06:host._poke_armed[side]=true
				elif distance<.035 and host._poke_armed[side]:host._poke_armed[side]=false;host.case.set_open(true);host._haptic(side)
	host._pressed[side]=grip


func _over_tray(at: Vector3) -> bool:
	var p: Vector3 = host.case.to_local(at)
	return absf(p.x)<.46 and absf(p.z)<.34 and p.y>-.10 and p.y<.48 and host.case.visible and host.case.opened


func _laser_input(side:String,sample:Dictionary) -> bool:
	var pointer:Node3D=host._pointers[side]
	var down:=float(sample.trigger)>(.3 if host._ray_pressed[side] else .65)
	var pressed:bool=down and not host._ray_pressed[side]
	host._ray_pressed[side]=down
	if not host.case.visible or host.case.amount<.95 or host.holding_case==side or (host.hand_busy(side) and not host.held.has(side)):
		pointer.hide();return false
	var aim:Transform3D=sample.get("aim",sample.pose)
	var point:Vector3=host.case.ray_point(aim.origin,-aim.basis.z)
	if not point.is_finite():
		pointer.hide()
		if pressed and host.held.has(side) and host.held[side].has_meta("ray_hold"):
			host._drop(side);return true
		return false
	var pixel:=Vector2(point.x,point.y)
	pointer.aim(aim.origin,host.case.world_point(pixel,.006))
	host._next_hover=host.case.ui.slot_at(pixel)
	if not pressed:return false
	if host.case.ui.CLOSE.has_point(pixel):
		if host.held.has(side) and not host._return_held(side):return true
		host._release_case();host.case.close()
	elif host.held.has(side):
		host._return_held(side)
	elif host._next_hover>=0:
		host.case.ui.selected=host._next_hover
		_select_slot(side,host._next_hover,sample.pose)
	else:host.activate(pixel,side,sample.pose)
	host._haptic(side);return true


func _stash_target(side:String,sample:Dictionary)->Dictionary:
	if host._desktop or not host.held.has(side) or host._map_open() or host.customizer.opened:return {}
	var item:RigidBody3D=host.held[side]
	var pose:Transform3D=sample.pose
	var palm:Vector3=sample.get("grip_position",pose.origin)
	if host.wrist.is_visible_in_tree():
		for point:Vector3 in [palm,item.global_position]:
			var local:Vector3=host.wrist.to_local(point)-Vector3(-host.WRIST_BUTTON_SPACING*.5,0,.025)
			if absf(local.x)<.055 and absf(local.y)<.05 and absf(local.z)<.10:
				return {"index":-1,"point":host.wrist.to_global(Vector3(-host.WRIST_BUTTON_SPACING*.5,0,.025))}
	var index:int=host.hotbar.slot_at(item.global_position,palm)
	if index>=0 and index<HOTBAR.SLOTS:
		var token:String=item.get_meta("token","")
		return {"index":index if host.inventory.can_put(token,index) else -1,"point":host.hotbar.to_global(Vector3((index-(HOTBAR.SLOTS-1)*.5)*HOTBAR.PITCH,0,0))}
	return {}


func _store_at_wrist(item:RigidBody3D,index:int=-1,destination:Vector3=Vector3.INF)->bool:
	var token:String=item.get_meta("token","")
	# Ownership is committed before a cosmetic effect. A failed write leaves the
	# object, grip and collision untouched; saving during the effect cannot clone it.
	if not host.loose.has(token) or host.loose[token]!=item:return false
	if not host.inventory.put(token,index):host._error();return false
	host._unglow(item)
	if host._book_open(item):item.get_node("BookItem").close_book()
	for side in host.held.keys():
		if host.held[side]==item:host.held.erase(side);host._track.erase(side);host._eat_time.erase(side);host._claim(side,false);host._haptic(side)
	host.loose.erase(token);host._refresh_holding()
	item.freeze=true;item.linear_velocity=Vector3.ZERO;item.angular_velocity=Vector3.ZERO
	item.collision_layer=0;item.collision_mask=0
	var visual:=item.get_child(1) as Node3D
	var at:=item.global_position
	var tween:=host.create_tween().bind_node(item)
	if destination.is_finite():tween.parallel().tween_property(item,"global_position",destination,.22)
	tween.parallel().tween_property(visual,"scale",visual.scale*.01,.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		SFX.play_at(host,"stow",at);item.queue_free())
	return true


func _over_wrist_icon(item:RigidBody3D)->bool:
	if host._desktop or not host.wrist.is_visible_in_tree() or host._map_open() or host.customizer.opened:return false
	if not host.hand_sample("left").get("active",false):return false
	var query:=PhysicsShapeQueryParameters3D.new();query.shape=host._wrist_drop_shape
	query.transform=host.wrist.global_transform.translated_local(Vector3(-.0435,0,.025))
	query.collision_mask=1<<17
	for hit in host.get_world_3d().direct_space_state.intersect_shape(query,host.MAX_LOOSE):
		if hit.collider==item:return true
	return false


## A hand holding an open book rests its visible fingers open behind the boards (dev 2026-10-15),
## so curled fingertips never come through the pages; the controller grip owns them again after.
var _book_rest := {}
func _book_fingers(side: String) -> void:
	var reading: bool = host.held.has(side) and host._book_open(host.held[side])
	if reading == bool(_book_rest.get(side, false)) or not is_instance_valid(host.avatar) or not host.avatar.has_method("set_grip"): return
	_book_rest[side] = reading
	host.avatar.set_grip(side, 0.0 if reading else null)


## VR: a held book. Trigger opens it, then turns forward; the holding hand's stick flicks turn
## either way; B/Y closes; the other hand's fingertip swiped across the pages turns them. Open, it
## sits at the hand facing your eyes, head of the page up.
func _book_hand(side: String, item: RigidBody3D, sample: Dictionary, _pose: Transform3D) -> void:
	var book:Node=item.get_node_or_null("BookItem")
	if book==null:return
	var pull:=float(sample.trigger)>.7
	if pull and not host._book_trigger[side]:
		if not book.opened:book.open_book()
		else:book.turn(1)
		host._haptic(side)
	host._book_trigger[side]=float(sample.trigger)>.3
	var c:Node=host.controllers.get(side)
	if book.opened and c!=null and c.has_method("get_vector2"):
		var x:float=c.get_vector2("primary").x
		var flick:=1 if x>.7 else -1 if x<-.7 else 0
		if flick!=0 and host._book_stick[side]==0 and book.turn(flick):host._haptic(side)
		host._book_stick[side]=flick if absf(x)>.35 else 0
		var shut:=bool(c.is_button_pressed("by_button"))
		if shut and not host._book_close[side]:book.close_book()
		host._book_close[side]=shut
	if not book.opened:return
	var other:="left" if side=="right" else "right"
	var other_sample: Dictionary = host.hand_sample(other)
	if other_sample.get("active",false) and not host.held.has(other):
		if book.swipe(other_sample.tip,Time.get_ticks_msec()/1000.0):host._haptic(other)
