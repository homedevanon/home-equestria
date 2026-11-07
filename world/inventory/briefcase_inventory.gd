extends Node3D
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Gesture + direct fingertip UI + owned physical items, shared by game and lab.
signal food_consumed(id: String)
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd") # Timed only while an F9 trace records.
const SFX := preload("res://world/audio/interaction_sounds.gd")
const ITEM_FOLEY := preload("res://world/audio/props_catalogue.gd")
const FOREARM_PANEL := preload("res://world/inventory/forearm_panel.gd")
const STORE := preload("res://world/inventory/inventory_store.gd")
const GLOVE_INDEX_CAP := {"left":Vector3(-.000082,.023418,-.001443),"right":Vector3(-.000202,.023418,-.001431)}
const CASE := preload("res://world/inventory/briefcase.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const FOOD := preload("res://world/food/food_interaction.gd")
const COOKING := preload("res://world/cooking/cooking_input.gd")
const STATION_INPUT := preload("res://world/mechanics/stations/station_input.gd")
const BANANAS := preload("res://world/food/banana_boxes.gd")
const GRAB := preload("res://world/inventory/grab_targets.gd")
const SHOP_ITEMS := preload("res://world/shop/shop_items.gd")
const SHOP_PURCHASE := preload("res://world/shop/shop_purchase.gd")
## Loaded only when a folding easel is used (world/painting/).
const EASEL_FOLD := "res://world/painting/easel_fold.gd"
const PHOTO_CAMERA := preload("res://world/items/photo_camera.gd")
const BOARD_FOLD := "res://world/minigames/board_games/board_fold.gd"
## Writing paper, letters and the quill (world/letters/, docs/LETTERS_PLAN_2026_10_29.md).
const LETTER_TOOL := preload("res://world/letters/paper/letter_tool.gd")
const QUILL_TOOL := preload("res://world/letters/paper/quill_tool.gd")
## Anon's notebook: the favours ponies asked of him on its pages (world/mechanics/asks/).
const NOTEBOOK_TOOL := preload("res://world/mechanics/asks/notebook_tool.gd")
## The photo journal, and a held print looked at up close (world/items/).
const PHOTO_JOURNAL := preload("res://world/items/photo_journal.gd")
const PHOTO_VIEW := preload("res://world/items/photo_view.gd")
const FURNISHING := preload("res://world/housing/home_furnishing.gd")
const PLACEMENT_PREVIEW := preload("res://world/housing/placement_preview.gd")
## AnonPony (docs/ANONPONY_DESIGN_2026_10_01.md section 9): things sit at her muzzle, a unicorn
## floats them in her magic, and she wears no clothes.
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const PONY_FORM := preload("res://player/pony_form.gd")
const PLAYER_MOUTH := preload("res://player/player_mouth.gd")
const MAGIC_AURA := preload("res://world/characters/magic/magic_aura.gd")
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
## A unicorn's carried thing floats in front of her eyes: 0.35 m ahead and 0.12 m down.
const UNICORN_FLOAT := Transform3D(Basis.IDENTITY, Vector3(0, -.12, -.35))

## Parts split out by responsibility (2026-10-13). Each is a RefCounted helper holding this
## node; the state stays here, with a forward for every name other scripts, tests,
## Callables or signal connections reach.
const MAGIC := preload("res://world/inventory/briefcase_magic.gd")
const DROPS := preload("res://world/inventory/briefcase_drops.gd")
const ITEM_USE := preload("res://world/inventory/briefcase_item_use.gd")
const HELD := preload("res://world/inventory/briefcase_held.gd")
const VR_HANDS := preload("res://world/inventory/briefcase_vr_hands.gd")
const DESKTOP := preload("res://world/inventory/briefcase_desktop.gd")
const WRIST := preload("res://world/inventory/briefcase_wrist.gd")
var _magic_part := MAGIC.new(self)
var _drops := DROPS.new(self)
var _item_use := ITEM_USE.new(self)
var _held_part := HELD.new(self)
var _vr_hands := VR_HANDS.new(self)
var _desktop_part := DESKTOP.new(self)
var _wrist_part := WRIST.new(self)

## The opening title hides the desktop hotbar (world/ui/title_vista.gd).
var hud_hidden := false
const LIBRARY := preload("res://world/books/book_library.gd")
const SIDES := ["left","right"]
## Books (dev 2026-09-26): the book itself opens in the hand and its pages carry the text
## (world/books/book_item.gd); no reader panel. VR: trigger opens, then turns pages; a stick flick
## on the holding hand or a swipe of the other hand across the pages turns too; B/Y closes.
## Desktop: a click opens and closes; wheel, arrows or left-click turn pages.
var _book_trigger := {"left":false,"right":false}
var _book_stick := {"left":0,"right":0}
var _book_close := {"left":false,"right":false}
const MAX_LOOSE := 24
var inspector:Node3D
var inventory: RefCounted
var case: Node3D
var camera: Camera3D
var player_body: Node
var map_menu: Node
var pony_grabber: Node
var hands: Dictionary = {}
var controllers: Dictionary = {}
var held: Dictionary = {}
var loose: Dictionary = {}
var holding_case := ""
var _case_offset := Transform3D.IDENTITY
var _pressed := {"left":false,"right":false}
var _poke_armed := {"left":false,"right":false}
var _last_tip: Dictionary = {}
var _cooking_armed := {"left": false, "right": false}
var _banana_armed := {"left": false, "right": false}
var _banana_palm: Dictionary = {}
var _tip_bones: Dictionary = {}
var _palm_bones: Dictionary = {}
var _forced: Dictionary = {}
var _quick_open := false
var _quick_origin := Vector3.ZERO
var _quick_grabs: Dictionary = {}
const QUICK_WALK_AWAY := 0.85
const QUICK_HAND_CLEARANCE := 0.18
const QUICK_WORLD_SCALE := 1.6
var _sweep_timer := 0.
var _desktop := false
var _mouse_before: int
var _mouse_origin := Vector2.ZERO
var _mouse_down := false
var _drag_slot := -1
var _moving_case := false
var _mouse_position := Vector2.ZERO
var _desktop_lock_owned := false
var _closed_pose := Transform3D.IDENTITY
var clothing: RefCounted
var customizer: Node3D
var wrist: Node3D
## Day and time above the wrist buttons (player bug board #18: an in-game clock).
var _watch: Label3D
var _wardrobe_lock_owned := false
var _mirror_drag := false
var _next_hover := -1
var avatar:Node3D
var _wrist_tip:Variant=null
var _wrist_armed:=false
const WRIST_BUTTON_SPACING := .087
const WRIST_HAND_CLEARANCE := .17
const WRIST_TOUCH_HALF := Vector3(.040, .043, .017)
const WRIST_RELEASE_MARGIN := .008
var _pointers:Dictionary={}
var _ray_pressed:Dictionary={"left":false,"right":false}
var _wrist_drop_shape:=BoxShape3D.new()
const HOTBAR := preload("res://world/inventory/wrist_hotbar.gd")
const EDIBLE := ["apple","carrot"]
const BITE_SECONDS := .45
const BITES := 3
var _selected_slots: Dictionary = {"left": -1, "right": -1, "desktop": -1}
var _hud_trigger_pressed: Dictionary = {"left": false, "right": false}
var _hud_trigger_claim: Dictionary = {"left": false, "right": false}
var _bar_grip_claim: Dictionary = {"left": false, "right": false}
var hotbar: Node3D
var _track: Dictionary = {}
var _eat_time: Dictionary = {}
var _desktop_eating := false
var grab_router: Node
var desktop_presentation: Node
var _desktop_pose_owned := false
var _crunch: AudioStreamPlayer3D

func setup(head: Camera3D, body: Node = null, left_hand: Node3D = null, right_hand: Node3D = null,
		left_controller: Node = null, right_controller: Node = null, world_map: Node = null,
		path: String = ""):
	camera=head;player_body=body;map_menu=world_map
	if get_node_or_null("PlacementPreview")==null:
		var preview:=PLACEMENT_PREVIEW.new();preview.name="PlacementPreview";add_child(preview);preview.setup(self)
	hands={"left":left_hand,"right":right_hand};controllers={"left":left_controller,"right":right_controller}
	_desktop=left_controller==null and right_controller==null
	add_to_group("interaction_hint_sources")
	inventory=STORE.new();inventory.open(path)
	case=CASE.new();add_child(case);case.setup(inventory)
	case.dismissed.connect(_dismissed)
	clothing=preload("res://world/customization/clothing_profile.gd").new()
	clothing.open("" if path.is_empty() else path.get_base_dir().path_join("clothing.json"))
	clothing.adopt_from_store(inventory) # older briefcases: bought outfits/sandals join the wardrobe
	if is_instance_valid(body) and "wing_flight" in body: clothing.flight_model = body.wing_flight
	clothing.changed.connect(_sync_flight_equipment)
	_sync_flight_equipment()
	if is_instance_valid(body) and body.get_parent()!=null:avatar=body.get_parent().find_child("AnonBody",true,false)
	if avatar!=null:clothing.attach(avatar)
	customizer=preload("res://world/customization/clothing_customizer.gd").new();add_child(customizer)
	customizer.setup(clothing,head,avatar);customizer.dismissed.connect(_clothes_dismissed)
	var pony_form:Node=_pony_form()
	if pony_form!=null:customizer.use_pony(pony_form.avatar)
	_build_wrist()
	for side in SIDES:
		var pointer:=preload("res://world/ui/controller_pointer.gd").new()
		add_child(pointer);_pointers[side]=pointer
	_wrist_drop_shape.size=Vector3(.078,.076,.10)
	_crunch=AudioStreamPlayer3D.new()
	_crunch.bus="SFX" if AudioServer.get_bus_index("SFX")>=0 else "Master"
	_crunch.stream=_bite_audio()
	_crunch.volume_db=-17;_crunch.max_distance=5;_crunch.max_polyphony=3;add_child(_crunch)
	hotbar=HOTBAR.new();hotbar.name="WristHotbar";add_child(hotbar);hotbar.setup(inventory,_desktop)
	hotbar.slot_selected.connect(_quick_slot)
	hotbar.slot_move.connect(_move_inventory_slot)
	if not inventory.last_error.is_empty():case.ui.message=inventory.last_error
	for side in SIDES:
		var h:Node=hands[side];var bone:=-1
		if is_instance_valid(h) and "skeleton" in h and h.skeleton!=null:
			for i in h.skeleton.get_bone_count():
				if h.skeleton.get_bone_name(i).ends_with("IndexTip"):bone=i
			if bone<0:bone=h.skeleton.find_bone(side.capitalize()+"IndexDistal")
		_tip_bones[side]=bone
		if is_instance_valid(h) and "skeleton" in h and h.skeleton!=null:
			var ids:=[]
			for ending in ["Hand","IndexProximal","LittleProximal","MiddleProximal"]:
				var found:=-1
				for i in h.skeleton.get_bone_count():
					if h.skeleton.get_bone_name(i)==side.capitalize()+ending:found=i
				ids.append(found)
			if -1 not in ids:_palm_bones[side]=ids
	if is_instance_valid(avatar) and avatar.has_signal("interaction_hands_updated"):
		avatar.interaction_hands_updated.connect(_sync_arm_panels)
	process_physics_priority=-40
	grab_router=preload("res://world/inventory/grab_router.gd").new()
	grab_router.inventory=self; add_child(grab_router)
	print("[inventory] ready: I opens the briefcase, 1-%d equip; VR hand-flip quick strip, point + grip" % HOTBAR.SLOTS)

func _move_inventory_slot(source: int, target: int) -> void:
	for side: String in held.keys():
		if not _return_held(side): return
	if inventory.move_slot(source, target): _play_deposit()

## The briefcase is the full inventory (dev 2026-09-28); the forearm hotbar is only quick slots.
func summon(open_immediately: bool = true):
	if _desktop and not _release_desktop_activity():return
	if inspector!=null and inspector.active:inspector.close()
	if not is_instance_valid(camera):return
	if customizer.opened:customizer.close(false)
	if wrist!=null:wrist.hide()
	if case.visible:
		if holding_case.is_empty():case.close()
		return
	_close_map()
	var forward:Vector3=-camera.global_basis.z;forward.y=0
	if forward.length_squared()<.01:forward=Vector3.FORWARD
	forward=forward.normalized()
	var basis:=Basis.looking_at(forward,Vector3.UP)
	# AnonPony's eye is low: the case rests about 0.3 m above the ground, not at a man's hip.
	var drop:=.53
	if _pony() and player_body is Node3D:
		drop=minf(.53,maxf(.15,camera.global_position.y-(player_body as Node3D).global_position.y-.30))
	case.summon(Transform3D(basis,camera.global_position+forward*.42+Vector3.DOWN*drop),open_immediately)
	if _desktop:
		_mouse_before=Input.mouse_mode
		Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
		if is_instance_valid(player_body) and "controls_locked" in player_body:
			_desktop_lock_owned=not player_body.controls_locked
			player_body.controls_locked=true

## Release the active activity before a menu records its lock snapshot. Adapters
## expose this no-argument hook; a refused release must preserve its current lock.
func _release_desktop_activity() -> bool:
	if not has_meta("desktop_activity_owner"):return true
	var owner:Node=get_meta("desktop_activity_owner")
	if not is_instance_valid(owner):remove_meta("desktop_activity_owner");return true
	if owner.has_method("cancel_desktop_activity"):owner.cancel_desktop_activity()
	return not has_meta("desktop_activity_owner") or not is_instance_valid(get_meta("desktop_activity_owner"))

func _close_map():
	if not is_instance_valid(map_menu):return
	if map_menu.has_method("set_open"):map_menu.set_open(false)
	elif map_menu.has_method("set_expanded"):map_menu.set_expanded(false)
func _map_open() -> bool:
	if not is_instance_valid(map_menu):return false
	return bool(map_menu.opened) if "opened" in map_menu else bool(map_menu.expanded)
func _dismissed():
	_moving_case=false;_mouse_down=false;_drag_slot=-1
	if customizer!=null and customizer.opened:return
	if _desktop:
		if _map_open() and is_instance_valid(map_menu) and "_previous_mouse_mode" in map_menu:
			map_menu._previous_mouse_mode=_mouse_before
		if _desktop_lock_owned and is_instance_valid(player_body):player_body.controls_locked=_map_open()
		_desktop_lock_owned=false
		if not _map_open():Input.mouse_mode=_mouse_before

func _open_clothes():
	if _desktop and not _release_desktop_activity():return
	if _pony():
		var form:Node=_pony_form()
		if form==null:return
		customizer.use_pony(form.avatar)
	if inspector!=null and inspector.active:inspector.close()
	if customizer.opened:customizer.close(false);return
	for side in held.keys():
		if not _return_held(side):return
	_release_case();wrist.hide();_close_map()
	if _desktop and not case.visible:_mouse_before=Input.mouse_mode
	if case.visible:case.close()
	if is_instance_valid(player_body) and "controls_locked" in player_body:
		_wardrobe_lock_owned=not player_body.controls_locked
		player_body.controls_locked=true
	if _desktop:Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
	customizer.show_menu()
func _clothes_dismissed():
	_mirror_drag=false
	if _wardrobe_lock_owned and is_instance_valid(player_body):player_body.controls_locked=_map_open()
	_wardrobe_lock_owned=false
	_dismissed()
func _build_wrist():
	wrist=Node3D.new();add_child(wrist)
	var mat:=StandardMaterial3D.new();mat.albedo_color=Color("343e3e");mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
	for i in 3:
		var mesh:=MeshInstance3D.new();var box:=BoxMesh.new();box.size=Vector3(.073,.068,.007)
		mesh.mesh=box;mesh.material_override=mat;mesh.position.x=(i-.5)*WRIST_BUTTON_SPACING;wrist.add_child(mesh)
		var icon:=Sprite3D.new();icon.texture=load("res://world/inventory/icons/briefcase.svg" if i==0 else ("res://world/customization/patterns/shirt_icon.svg" if i==1 else "res://world/ui/profile/icons/scan-eye.svg"))
		icon.pixel_size=.00045 if i==2 else .00039;icon.position=Vector3(mesh.position.x,0,.005);icon.double_sided=false;icon.shaded=false;wrist.add_child(icon)
	_watch = Label3D.new(); _watch.pixel_size = 0.00022; _watch.font_size = 64; _watch.outline_size = 12
	_watch.position = Vector3(WRIST_BUTTON_SPACING * .5, 0.054, 0.005); _watch.double_sided = false; _watch.shaded = false
	wrist.add_child(_watch); _tell_time()
	var carrier := FOREARM_PANEL.new(); wrist.add_child(carrier)
	if _desktop:
		# Desktop has no arm to look at: Tab floats these buttons in front of the view, so each
		# carries its name and key.
		for i in 3:
			var caption := Label3D.new(); caption.text = ["Briefcase  I", "Clothes  U", "Ponies  J"][i]
			caption.pixel_size = 0.00022; caption.font_size = 48; caption.outline_size = 10
			caption.position = Vector3((i - .5) * WRIST_BUTTON_SPACING, -0.05, 0.005); caption.double_sided = false
			wrist.add_child(caption)
		carrier.fit(Rect2(-0.086, -0.064, 0.259, 0.134), -0.0035)
	else:
		carrier.fit(Rect2(-0.086, -0.040, 0.259, 0.110), -0.0035)
	wrist.hide()

func _tell_time() -> void:
	# Looked up, not named: fixtures load this script without the autoloads.
	var clock: Node = get_node_or_null("/root/TimeOfDay")
	if _watch != null and clock != null: _watch.text = "Day %d   %s" % [int(clock.day) + 1, clock.time_string()]

func _wrist_input(side: String, sample: Dictionary) -> bool:
	return _wrist_part._wrist_input(side, sample)

func hand_busy(side: String) -> bool:
	if side=="desktop" and has_meta("desktop_activity_owner") and is_instance_valid(get_meta("desktop_activity_owner")):return true
	if held.has(side) or holding_case==side:return true
	if side in SIDES and is_instance_valid(pony_grabber) and pony_grabber.is_holding(side):return true
	var hand:Variant=hands.get(side)
	return is_instance_valid(hand) and (hand.get_meta("inventory_busy",false) or ("held_object" in hand and is_instance_valid(hand.held_object)))
## The hand's only load is an equipped hotbar item: it may put the item away by itself to take a
## door handle (dev 2026-09-28: handles stopped working once the hotbar kept an item in hand).
func equipped_only(side: String) -> bool:
	if not held.has(side) or holding_case == side: return false
	if not inventory.loans.get(str(held[side].get_meta("token")), {}).get("equipped", false): return false
	if side in SIDES and is_instance_valid(pony_grabber) and pony_grabber.is_holding(side): return false
	var hand: Variant = hands.get(side)
	return not (is_instance_valid(hand) and "held_object" in hand and is_instance_valid(hand.held_object))
func _claim(side: String, busy: bool):
	# Releasing an inventory hold consumes this squeeze, including explicit stow/drop.
	if not busy and grab_router != null and side in SIDES: grab_router.consume(side)
	var hand:Variant=hands.get(side)
	if is_instance_valid(hand):
		if busy:hand.set_meta("inventory_busy",true)
		else:hand.remove_meta("inventory_busy")
func set_hand_input(side: String, sample: Variant):
	if sample==null:_forced.erase(side)
	else:_forced[side]=sample
func hand_sample(side: String) -> Dictionary:
	if _forced.has(side):return _forced[side]
	var c:Node=controllers.get(side);var h:Node3D=hands.get(side)
	if not is_instance_valid(c) or not is_instance_valid(h):return {"active":false}
	if c.has_method("get_is_active") and not c.get_is_active():return {"active":false}
	if c.has_method("get_has_tracking_data") and not c.get_has_tracking_data():return {"active":false}
	var tip:Vector3=h.global_position
	var bone:int=_tip_bones.get(side,-1)
	if bone>=0:tip=(h.skeleton.global_transform*h.skeleton.get_bone_global_pose(bone)).origin
	var palm:Vector3=-h.global_basis.y
	var pose:Transform3D=h.global_transform
	var grip_position: Vector3 = pose.origin
	# Glove fallback reads the cached post-modifier pose too. The imported Valve
	# skeleton has IndexDistal, not IndexTip; never silently use the palm as a tip.
	if bone>=0 and "poses" in h.skeleton and h.skeleton.poses.has(bone):
		var distal:Transform3D=h.skeleton.poses[bone]
		tip=(h.global_transform*distal).origin
		if h.skeleton.get_bone_name(bone).ends_with("IndexDistal"):
			tip=h.global_transform*distal*GLOVE_INDEX_CAP[side]
	if _palm_bones.has(side):
		var points:Array[Vector3]=[]
		for i in _palm_bones[side]:
			var bone_pose:Transform3D=h.skeleton.poses[i] if "poses" in h.skeleton and h.skeleton.poses.has(i) else h.skeleton.get_bone_global_pose(i)
			points.append((h.global_transform*bone_pose).origin)
		# Finger x thumb side: the palm, not the back (same fix as anon_body.gd, 2026-10-15).
		var normal:Vector3=(points[3]-points[0]).cross(points[1]-points[2])
		if normal.length_squared()>.0000001:palm=normal.normalized()*(1. if side=="left" else -1.)
		grip_position = (points[0] + (points[1] + points[2] + points[3]) / 3.0) * 0.5
	if is_instance_valid(avatar) and avatar.has_method("interaction_hand"):
		var visible_hand:Dictionary=avatar.interaction_hand(side)
		if not visible_hand.is_empty():
			tip=visible_hand.tip;palm=visible_hand.palm
			grip_position = visible_hand.get("palm_center", grip_position)
			if c is Node3D:pose=c.global_transform
	return {"active":true,"pose":pose,"aim":c.global_transform,"grip_position":grip_position,"tip":tip,"palm":palm,"grip":c.get_float("grip"),"trigger":c.get_float("trigger")}
func _haptic(side: String):
	var c:Node=controllers.get(side)
	if c is XRController3D and c.get_is_active():c.trigger_haptic_pulse("haptic",0.,.22,.035,0.)

func _physics_process(delta: float):
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_physics_step(delta)
	if started > 0: CPU_PROFILE.record("inventory", started)

func _physics_step(delta: float):
	if case==null:return
	if case.visible and holding_case.is_empty() and not _moving_case and is_instance_valid(camera) and case.global_position.distance_to(camera.global_position) > 2.0:
		case.close()
	if is_instance_valid(map_menu) and _map_open() and case.visible:
		_release_case();case.close()
	if _desktop_wrist and (_map_open() or case.visible or customizer.opened or (inspector!=null and inspector.active)):
		_toggle_desktop_wrist(false)
	if _map_open():
		wrist.hide()
		if customizer.opened:customizer.close(false)
	_next_hover=-1
	_place_hotbar()
	# Reuse only this tick's samples; render-frame placement keeps sampling tracking live.
	var left_sample: Dictionary = hand_sample("left")
	_update_hand("left",left_sample,delta)
	var right_sample: Dictionary = hand_sample("right")
	_update_hand("right",right_sample,delta)
	if not _desktop:_set_hover(_next_hover)
	_gesture(left_sample,delta)
	_quick_gesture(right_sample,delta)
	if _desktop and held.has("desktop"):
		var item:RigidBody3D=held.desktop
		if case.visible:
			var direction:=camera.project_ray_normal(_mouse_position)
			item.global_transform=Transform3D(camera.global_basis,camera.project_ray_origin(_mouse_position)+direction*.36)
		elif _book_open(item):
			# Reading: the open book held up in front of you, pages toward your eyes, head of
			# the page up (book +Y -> view +Z, book -Z -> view up).
			item.global_transform=camera.global_transform*Transform3D(Basis(Vector3.RIGHT,Vector3.BACK,Vector3.DOWN),Vector3(0,-.02,-.46)*PLAYER_MOUTH.human_scale(camera))
		else:
			# Held low and to the right of the view, like a hand in front of you. Every AnonPony
			# floats it in front of her eyes in her magic (dev 2026-10-02: "make items always float
			# in front of you with magic even if youre an earth pony/pegasus"; her arms are invisible).
			var hold:Transform3D=camera.global_transform*UNICORN_FLOAT if _pony_form()!=null else PLAYER_MOUTH.hold_transform(camera,Transform3D(Basis.IDENTITY,Vector3(.19,-.16,-.30)))
			item.global_transform=_held_clear(item,_held_world(item,hold))
			if FOOD.has(str(item.get_meta("item_id", ""))):FOOD.desktop_raise(item,camera,_desktop_eating,delta)
		_track_item("desktop",item)
		_eat_tick("desktop",item,delta,_desktop_eating and not case.visible)
		if held.has("desktop"):_present_desktop_item(item)
	if _desktop:_sync_magic()
	if _moving_case:
		case.global_position=camera.project_ray_origin(_mouse_position)+camera.project_ray_normal(_mouse_position)*.60
	_sweep_timer+=delta
	if case.visible and case.opened:
		for token in loose.keys():
			var dropped:RigidBody3D=loose[token]
			if dropped.get_meta("outside_drop",false):
				if _over_tray(dropped.global_position): continue
				dropped.remove_meta("outside_drop")
			if dropped not in held.values() and _over_tray(dropped.global_position):
				if inventory.put(token):
					loose.erase(token);dropped.queue_free();_play_deposit()
	if _sweep_timer>1.:
		_sweep_timer=0.
		_sync_dropped_items()

## The VR rig walks every rendered frame (xr_grounded_body.gd). Placing hand-borne things only
## on physics ticks would leave them trailing the hand while walking, so re-place them here.
func _process(_delta: float) -> void:
	var started := Time.get_ticks_usec() if CPU_PROFILE.enabled else 0
	_process_step(_delta)
	if started > 0: CPU_PROFILE.record("inventory", started)

func _process_step(_delta: float) -> void:
	if wrist != null and wrist.visible: _tell_time()
	if _desktop or case==null:return
	_place_hotbar()
	for side:String in held.keys():
		if side not in SIDES:continue
		var sample:=hand_sample(side)
		var item:RigidBody3D=held[side]
		if sample.get("active",false) and float(item.get_meta("hold_blend",1.))>=1.:
			item.global_transform=_held_clear(item,_held_world(item,sample.pose,sample))
	if holding_case in SIDES:
		var sample:=hand_sample(holding_case)
		if sample.get("active",false):case.global_transform=Transform3D(sample.pose)*_case_offset
	if wrist.visible and not _head_hud():
		var sample:=hand_sample("left")
		if sample.get("active",false):_place_wrist(sample.pose)
		else:_hide_wrist_mount()

func _gesture(sample: Dictionary, delta: float):
	return _wrist_part._gesture(sample, delta)

func _sync_arm_panels()->void:
	_wrist_part._sync_arm_panels()

func _hide_wrist_mount()->void:
	_wrist_part._hide_wrist_mount()

func _place_wrist(pose:Transform3D)->bool:
	return _wrist_part._place_wrist(pose)

func _head_hud() -> bool:
	return _wrist_part._head_hud()

func _quick_blocked() -> bool:
	return _wrist_part._quick_blocked()


func _quick_gesture(sample: Dictionary, delta: float) -> void:
	_wrist_part._quick_gesture(sample, delta)

func _grab_snapshot() -> Dictionary:
	return _wrist_part._grab_snapshot()

func _dismiss_quick_strip() -> void:
	_wrist_part._dismiss_quick_strip()

func _summon_quick_strip(pose: Transform3D) -> void:
	if _desktop or _quick_blocked() or not pose.is_finite() or not is_instance_valid(camera): return
	var at := pose.origin + Vector3.UP * QUICK_HAND_CLEARANCE
	var direction := at - camera.global_position
	if not direction.is_finite() or direction.length_squared() < .01: return
	var up := Vector3.UP if absf(direction.normalized().dot(Vector3.UP)) < .95 else camera.global_basis.y
	if hotbar.get_parent() != self:
		preload("res://world/ui/head_locked_hud.gd").detach(camera, hotbar)
		hotbar.reparent(self, false)
	hotbar.top_level = true
	hotbar.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	hotbar.set_world_popup(true)
	hotbar.global_transform = Transform3D(Basis.looking_at(direction.normalized(), up).scaled(Vector3.ONE * QUICK_WORLD_SCALE), at)
	_quick_origin = camera.global_position
	_quick_grabs = _grab_snapshot()
	_quick_open = true
	hotbar.show(); _haptic("right")

func _place_hotbar():
	return _wrist_part._place_hotbar()

## Where a held item sits: the hand pose times the item's grip, easing in after a grab.
static func hold_local(id:String)->Transform3D:
	return HELD.hold_local(id)
func _held_world(item:RigidBody3D,pose:Transform3D,sample:Dictionary={})->Transform3D:
	return _held_part._held_world(item, pose, sample)
## Put on a bought outfit (world/shop/shop_items.gd): its colours and patterns replace Anon's
## current suit, tie, trousers and shirt, the jacket and trousers go on, and it is saved. The
## folded clothes stay his, to switch back and forth. AnonPony wears none, and never writes them.
func wear_outfit(item: Node) -> bool:
	return _item_use.wear_outfit(item)

func _sync_flight_equipment() -> void:
	_item_use._sync_flight_equipment()

func _held_clear(item:RigidBody3D,target:Transform3D)->Transform3D:
	return _held_part._held_clear(item, target)

func _track_item(side:String,item:RigidBody3D):
	return _held_part._track_item(side, item)
func _release_velocity(side:String)->Array:
	return _held_part._release_velocity(side)
func _mouth()->Vector3:
	return _item_use._mouth()
## Food held at the mouth is eaten in three bites.
func _eat_tick(side:String,item:RigidBody3D,delta:float,near:bool)->bool:
	if FOOD.has(str(item.get_meta("item_id", ""))):
		# Desktop: holding the button eats what you hold, wherever you look (dev 2026-10-01:
		# eating "shouldnt be reliant on literally facing the thing"; looking down at the stump
		# the raised food stopped against it short of a pony's muzzle and never got eaten).
		var food_id: String = str(item.get_meta("item_id", ""))
		var food_token: String = str(item.get_meta("token", ""))
		var eaten: bool = FOOD.eat_tick(self,side,item,delta,near and (side=="desktop" or FOOD.mouth_near(item,_mouth())))
		if eaten or (inventory.loans.has(food_token) and inventory.loans[food_token].id != food_id):
			get_tree().call_group("picnic_consumption", "food_consumed", item, food_id, food_token)
			food_consumed.emit(food_id)
		return eaten
	if String(item.get_meta("item_id","")) not in EDIBLE or not near:
		_eat_time.erase(side);return false
	_eat_time[side]=float(_eat_time.get(side,0.))+delta
	if _eat_time[side]<BITE_SECONDS:return false
	_eat_time[side]=0.
	var bites:int=int(item.get_meta("bites",0))+1
	var token:String=item.get_meta("token")
	if bites<BITES:
		if not inventory.set_bites(token,bites):_error();return false
	else:
		if not inventory.consume(token):_error();return false
	item.set_meta("bites",bites)
	_play_food_use(str(item.get_meta("item_id","")),_mouth());_haptic(side)
	if bites<BITES:
		(item.get_child(1) as Node3D).scale*=.78;return false
	get_tree().call_group("player_needs","ate",String(item.get_meta("item_id","")))
	food_consumed.emit(String(item.get_meta("item_id","")))
	held.erase(side);loose.erase(token);_claim(side,false);_track.erase(side);_eat_time.erase(side)
	item.queue_free();_refresh_holding()
	return true


func _hotbar_input(side: String, sample: Dictionary, grip: bool, trigger_edge: Variant = null) -> bool:
	return _vr_hands._hotbar_input(side, sample, grip, trigger_edge)


func _select_slot(side: String, index: int, pose: Transform3D) -> bool:
	return _vr_hands._select_slot(side, index, pose)

func _banana_entry(side: String, sample: Dictionary) -> bool:
	return _vr_hands._banana_entry(side, sample)

func _update_hand(side: String, sample: Dictionary, delta: float):
	# UI handlers may return early, but a released grip must always re-arm. Keeping
	# this outside those handlers prevents a previous squeeze from latching forever.
	var down: bool = sample.get("active", false) and float(sample.get("grip", 0.0)) > (.25 if _pressed[side] else .45)
	_update_hand_step(side, sample, delta)
	_pressed[side] = down

func _update_hand_step(side: String, sample: Dictionary, _delta: float):
	return _vr_hands._update_hand_step(side, sample, _delta)

func _over_tray(at: Vector3) -> bool:
	return _vr_hands._over_tray(at)

func _laser_input(side:String,sample:Dictionary) -> bool:
	return _vr_hands._laser_input(side, sample)

func _play_purchase(item:Node3D) -> void:
	_item_use._play_purchase(item)

func _play_food_use(id:String,at:Vector3) -> void:
	_item_use._play_food_use(id, at)

func _play_item_pickup(item:Node3D) -> void:
	_item_use._play_item_pickup(item)

func _play_select() -> void:
	_item_use._play_select()

func _play_deposit() -> void:
	_item_use._play_deposit()

static func _bite_audio() -> AudioStream:
	return ITEM_USE._bite_audio()


func _store_at_wrist(item:RigidBody3D,index:int=-1,destination:Vector3=Vector3.INF)->bool:
	return _vr_hands._store_at_wrist(item, index, destination)

func _over_wrist_icon(item:RigidBody3D)->bool:
	return _vr_hands._over_wrist_icon(item)
func activate(pixel: Vector2, side: String = "desktop", pose := Transform3D.IDENTITY):
	if case.amount<.95:return
	if case.ui.CLOSE.has_point(pixel):case.close();return
	var index:int=case.ui.slot_at(pixel)
	if index>=0:
		case.ui.selected=index;case.ui.message="";case.ui.refresh();return
	if case.ui.TAKE.has_point(pixel):_select_slot(side,case.ui.selected,pose)
	elif case.ui.STORE.has_point(pixel):_return_held(side)

func take_slot(side: String, index: int, pose := Transform3D.IDENTITY, from_case := true) -> bool:
	return _held_part.take_slot(side, index, pose, from_case)
func _make_item(token: String, id: String, visual: Node3D) -> RigidBody3D:
	return _drops._make_item(token, id, visual)

## The open sheet of the letter, notebook or journal in this hand, or null.
func _open_sheet(item: Node) -> Node3D:
	var sheet: Node3D = null
	if NOTEBOOK_TOOL.handles(item): sheet = NOTEBOOK_TOOL.on(item as Node3D).pages()
	elif PHOTO_JOURNAL.handles(item): sheet = PHOTO_JOURNAL.on(item as Node3D).sheet()
	elif LETTER_TOOL.handles(item): sheet = LETTER_TOOL.on(item as Node3D).letter_sheet()
	return sheet if sheet != null and bool(sheet.get("opened")) else null

## Physical activity reward: commit ownership and its world placement together,
## then expose the body. A rejected transaction never spawns a free duplicate.
func spawn_owned_drop(id:String,pose:Transform3D)->RigidBody3D:
	return _drops.spawn_owned_drop(id, pose)

func _lay_out_blanket(side: String) -> bool:
	var picnic: Node = get_tree().get_first_node_in_group("picnic_runtime")
	return picnic != null and held.has(side) and picnic.lay_out(side, held[side])

func _configure_picnic(item: RigidBody3D, token: String) -> void:
	if not is_instance_valid(item) or not inventory.loans.get(token, {}).get("picnic_deployed", false): return
	var picnic: Node = get_tree().get_first_node_in_group("picnic_runtime")
	if picnic != null: picnic.configure(item, token)

func checkpoint_drops() -> bool:
	return _drops.checkpoint_drops()

func _drop_supported(pose: Transform3D, id: String = "") -> bool:
	return _drops._drop_supported(pose, id)

func _sync_dropped_items() -> void:
	_drops._sync_dropped_items()

func restore_drops() -> void:
	_drops.restore_drops()

func _take_nearby(side: String, pose: Transform3D, aim: Variant = null) -> bool:
	return _held_part._take_nearby(side, pose, aim)

func grab_take(side: String, offer: Dictionary, sample: Dictionary) -> bool:
	return _held_part.grab_take(side, offer, sample)

func _take_pick(side: String, pick: Dictionary, pose: Transform3D) -> bool:
	if hand_busy(side) or not is_instance_valid(pick.get("target")): return false
	if pick.is_empty():return false
	# Cached offers from another acquisition path may outlive the first hand's
	# pickup. The physical item and its loan still have exactly one hand owner.
	if pick.target in held.values(): return false
	if bool(pick.get("pointed",false)):
		(pick.target as Node3D).set_meta("hold_blend_seconds",PULL_SECONDS)
		# Taken where it lies (the reach checks pass there); the hold blend flies it in.
		pose=Transform3D(pose.basis,(pick.target as Node3D).global_position)
	match str(pick.kind):
		"food":return FOOD.take_world(self,side,pick.target,pose)
		"shop":return SHOP_PURCHASE.take_world(self,side,pick.target,pose)
		"book":return _take_shelf_book(side,pick.target,pose)
	var candidate:RigidBody3D=pick.target
	var picnic: Node = get_tree().get_first_node_in_group("picnic_runtime")
	var deployed: bool = inventory.loans.get(str(candidate.get_meta("token", "")), {}).get("picnic_deployed", false)
	if deployed and (picnic == null or not picnic.can_pack(candidate)):
		inventory.last_error = "Clear the blanket before packing it."; _error(); return false
	if candidate.has_meta("board_table_root") and not load(BOARD_FOLD).can_pack(candidate):
		inventory.last_error = "Finish or resign the game before packing the board."; _error(); return false
	if not inventory.pick_up(String(candidate.get_meta("token"))): _error(); return false
	preload("res://world/cooking/cooking_station.gd").presentation(candidate, false)
	preload("res://world/housing/home_furnishing.gd").configure(candidate, false)
	if deployed: picnic.fold_visual(candidate)
	if candidate.has_meta("painting_easel_root"): load(EASEL_FOLD).fold_visual(candidate)
	if candidate.has_meta("board_table_root"): load(BOARD_FOLD).fold_visual(candidate)
	if candidate.has_meta("outside_drop"): candidate.remove_meta("outside_drop")
	candidate.freeze=true;candidate.linear_velocity=Vector3.ZERO;candidate.angular_velocity=Vector3.ZERO
	var grip:=hold_local(String(candidate.get_meta("item_id","")))
	if side!="desktop" and String(candidate.get_meta("item_id","")) not in ["carrot","food:carrot"]:grip.basis=(pose.basis.orthonormalized().inverse()*candidate.global_basis.orthonormalized()).orthonormalized()
	candidate.set_meta("hold_offset",grip);candidate.set_meta("hold_from",candidate.global_transform);candidate.set_meta("hold_blend",0.)
	held[side]=candidate;_track.erase(side);_claim(side,true);_refresh_holding();_haptic(side);_play_item_pickup(candidate);return true
func _book_open(item: Node) -> bool:
	var book:Node=item.get_node_or_null("BookItem")
	return book!=null and book.opened


func _take_shelf_book(side: String, book: Node3D, pose: Transform3D) -> bool:
	return _held_part._take_shelf_book(side, book, pose)
func _store_held(side: String, index: int = -1) -> bool:
	return _held_part._store_held(side, index)
func _return_held(side: String) -> bool:
	return _held_part._return_held(side)

func _release_to_world(side:String)->void:
	_held_part._release_to_world(side)

## Dropped things come to rest instead of rolling off down every slope (dev 2026-10-01: "nowhere
## is perfectly flat").
## A pointed-at thing flies into the hand over this long.
const PULL_SECONDS := 0.3
func _settle(item:RigidBody3D)->void:
	_held_part._settle(item)
func shelf_offer(side: String) -> Node3D:
	return _held_part.shelf_offer(side)

func _shelve_held(side: String) -> bool:
	return _held_part._shelve_held(side)

func _drop(side: String, push := Vector3.ZERO):
	return _held_part._drop(side, push)
func _release_case():
	return _held_part._release_case()
func _refresh_holding():
	return _held_part._refresh_holding()
func _error():
	case.ui.message=inventory.last_error if not inventory.last_error.is_empty() else "That slot cannot accept this item."
	var insufficient: bool = case.ui.message == "insufficient funds!"
	if hotbar != null: hotbar.set_message(case.ui.message, insufficient)
	if insufficient: case.ui.flash_message()
	case.ui.refresh()

func _clear_purchase_error() -> void:
	if case.ui.message == "insufficient funds!": case.ui.message = ""; case.ui.refresh()
	if hotbar != null and hotbar.message == "insufficient funds!": hotbar.set_message("")

func _input(event: InputEvent):
	if not _desktop or case==null:return
	# The last bite can remove the held object before button-up reaches this node.
	if event is InputEventMouseButton and not event.pressed and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_desktop_eating = false
	if FLIGHT_INPUT.reserves_mouse(event,player_body):
		_desktop_eating = false
		return
	var typed_focus:Control=get_viewport().gui_get_focus_owner()
	if typed_focus is LineEdit or typed_focus is TextEdit:return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_I,KEY_U,KEY_TAB,KEY_J]:
		if not _release_desktop_activity():return
	# An activity owns the active hand until its adapter releases it.
	if has_meta("desktop_activity_owner") and is_instance_valid(get_meta("desktop_activity_owner")):
		_desktop_eating = false
		return
	# Inventory may handle its own lock; title/sleep/pause own every other lock.
	if is_instance_valid(player_body) and "controls_locked" in player_body and player_body.controls_locked and not _desktop_lock_owned and not _wardrobe_lock_owned and not _wrist_lock_owned:
		_desktop_eating = false
		return
	if event is InputEventKey and event.pressed and held.has("desktop") and event.physical_keycode in [KEY_LEFT,KEY_RIGHT]:
		var book:Node=held.desktop.get_node_or_null("BookItem")
		if book!=null and book.opened:
			book.turn(1 if event.physical_keycode==KEY_RIGHT else -1);get_viewport().set_input_as_handled();return
	# Typing in the chat box (or any text field) is not a command.
	if get_viewport().gui_get_focus_owner() is LineEdit or get_viewport().gui_get_focus_owner() is TextEdit:return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_TAB:
		_toggle_desktop_wrist(not _desktop_wrist);get_viewport().set_input_as_handled();return
	if _desktop_wrist:
		if event is InputEventKey and event.pressed and event.physical_keycode==KEY_ESCAPE:
			_toggle_desktop_wrist(false);get_viewport().set_input_as_handled();return
		if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
			_desktop_wrist_click(event.position);get_viewport().set_input_as_handled();return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode==KEY_I:
			if _desktop_wrist:_toggle_desktop_wrist(false)
			summon(true);get_viewport().set_input_as_handled();return
		if event.physical_keycode==KEY_U:
			_open_clothes();get_viewport().set_input_as_handled();return
		if customizer.opened and event.physical_keycode==KEY_ESCAPE:
			customizer.close(false);get_viewport().set_input_as_handled();return
		if case.visible and event.physical_keycode==KEY_ESCAPE:
			case.close();get_viewport().set_input_as_handled();return
		if not customizer.opened and not event.shift_pressed and event.physical_keycode>=KEY_1 and event.physical_keycode<KEY_1+HOTBAR.SLOTS:
			_quick_slot(event.physical_keycode-KEY_1);get_viewport().set_input_as_handled();return
		if not case.visible and not customizer.opened and Input.mouse_mode==Input.MOUSE_MODE_CAPTURED:
			# Q throws what is in hand (dev 2026-09-30); Shift+Q sets it down gently in front.
			# Seated, lying or sitting on the ground, Q stands you up instead (desktop_player.gd, dev 2026-10-22).
			if event.physical_keycode==KEY_Q and held.has("desktop") and not (_q_stands() and event.is_action("stand_up")):
				if event.shift_pressed:
					if not desktop_place():_drop("desktop",-camera.global_basis.z*1.2)
				else:_drop("desktop",-camera.global_basis.z*7.+Vector3.UP*1.8)
				get_viewport().set_input_as_handled();return
			if event.physical_keycode == KEY_E and not COOKING.offer(self,"desktop").is_empty():
				COOKING.activate(self,"desktop")
				get_viewport().set_input_as_handled();return
			# E on an easel's canvas, tray or hooks starts painting (world/painting/easel_wake.gd).
			if event.physical_keycode == KEY_E and _desktop_easel_begin():
				get_viewport().set_input_as_handled();return
			if event.physical_keycode == KEY_E and _shelve_held("desktop"):
				get_viewport().set_input_as_handled();return
			# E takes what you look at straight into the briefcase (dev 2026-09-30).
			if event.physical_keycode==KEY_E and stash_take():
				get_viewport().set_input_as_handled();return
	# Holding something, a click uses it (dev 2026-09-30: "clicking should be interact/use", Q
	# throws): left and right click alike. A thing with no use of its own lets the click through
	# to the world (a door, a seat) for the interactor.
	if event is InputEventMouseButton and not case.visible and not customizer.opened and Input.mouse_mode==Input.MOUSE_MODE_CAPTURED and held.has("desktop"):
		var use_click:bool=event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]
		if use_click and not COOKING.offer(self,"desktop").is_empty():
			if event.pressed:COOKING.activate(self,"desktop")
			get_viewport().set_input_as_handled();return
		# Mechanics stations (world/mechanics/stations/station_input.gd): the nearest station node
		# takes the click, and the release of a click it took.
		if use_click and STATION_INPUT.offer(self,"desktop",event.pressed):
			get_viewport().set_input_as_handled();return
		# Looking at a pony's face up close with anything giftable: the click offers it to her
		# (world/relationships/hand_feeding.gd, P2a gifts). Tools are not giftable, so they keep their use.
		var gift_to:Node=get_tree().get_first_node_in_group("hand_feeding")
		if use_click and gift_to!=null and CATALOG.has_tag(str(held.desktop.get_meta("item_id","")),"giftable") and gift_to.desktop_target()!=null:
			if event.pressed:gift_to.desktop_offer()
			get_viewport().set_input_as_handled();return
		if use_click and held.desktop.get_meta("item_id", "") == "goods:folded-blanket":
			if event.pressed: _lay_out_blanket("desktop")
			get_viewport().set_input_as_handled(); return
		if use_click and held.desktop.get_meta("item_id", "") == "goods:easel":
			if event.pressed: load(EASEL_FOLD).unfold(self, "desktop")
			get_viewport().set_input_as_handled(); return
		# The photo camera: hold right click to look through it, click to take the photo.
		if use_click and held.desktop.get_meta("item_id", "") == "goods:camera":
			var photo_camera: Node3D = PHOTO_CAMERA.on(held.desktop)
			if event.button_index == MOUSE_BUTTON_RIGHT: photo_camera.set_looking(event.pressed, camera)
			elif event.pressed: photo_camera.snap(self, camera)
			get_viewport().set_input_as_handled(); return
		if use_click and held.desktop.get_meta("item_id", "") == "goods:game-board":
			if event.pressed: load(BOARD_FOLD).unfold(self, "desktop")
			get_viewport().set_input_as_handled(); return
		# A held print: a click looks at it, the wheel brings it closer; over a home wall the wheel
		# picks its size (or turns floor furniture), green or red in the placement preview.
		var wheel_step: int = 1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else 0
		if PHOTO_VIEW.handles(held.desktop):
			var photo_view: Node3D = PHOTO_VIEW.on(held.desktop)
			if use_click:
				if event.pressed: photo_view.toggle(self)
				get_viewport().set_input_as_handled(); return
			if wheel_step != 0 and event.pressed and photo_view.viewing():
				photo_view.zoom(wheel_step)
				get_viewport().set_input_as_handled(); return
		if wheel_step != 0 and event.pressed and FURNISHING.wheel(self, "desktop", wheel_step):
			get_viewport().set_input_as_handled(); return
		# An open letter, notebook or journal page: the wheel brings it closer, right click goes back.
		var reading: Node3D = _open_sheet(held.desktop)
		if reading != null and event.pressed:
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				reading.zoom(1 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1)
				get_viewport().set_input_as_handled(); return
			if event.button_index == MOUSE_BUTTON_RIGHT and int(reading.get("page")) > 0:
				reading.previous_page()
				get_viewport().set_input_as_handled(); return
		# Paper and letters: a click starts, opens or reads; a click held a second sends a draft
		# with Derpy (world/letters/paper/letter_tool.gd).
		if use_click and NOTEBOOK_TOOL.handles(held.desktop):
			NOTEBOOK_TOOL.on(held.desktop).press(self, "desktop", event.pressed)
			get_viewport().set_input_as_handled(); return
		if use_click and PHOTO_JOURNAL.handles(held.desktop):
			PHOTO_JOURNAL.on(held.desktop).press(self, "desktop", event.pressed)
			get_viewport().set_input_as_handled(); return
		if use_click and LETTER_TOOL.handles(held.desktop):
			LETTER_TOOL.on(held.desktop).press(self, "desktop", event.pressed)
			get_viewport().set_input_as_handled(); return
		# The quill writes by voice in VR; on desktop letters are typed, so its click does nothing.
		if use_click and held.desktop.get_meta("item_id", "") == "goods:quill":
			get_viewport().set_input_as_handled(); return
		# The spa's hoof file: a click files a raised hoof (world/minigames/spa/spa_hands.gd), never an offer.
		if use_click and held.desktop.get_meta("item_id", "") == "hoof-file": return
		if held.desktop.get_meta("item_id", "") == "spray-bottle" and use_click:
			if event.pressed: held.desktop.get_node("SprayBottle").spray()
			get_viewport().set_input_as_handled(); return
		var desk_book:Node=held.desktop.get_node_or_null("BookItem") if CATALOG.is_book(String(held.desktop.get_meta("item_id",""))) else null
		if desk_book!=null:
			if desk_book.opened and event.pressed and event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_WHEEL_DOWN,MOUSE_BUTTON_WHEEL_UP]:
				desk_book.turn(-1 if event.button_index==MOUSE_BUTTON_WHEEL_UP else 1)
				get_viewport().set_input_as_handled();return
			if event.pressed and use_click:
				if desk_book.opened:desk_book.close_book()
				else:desk_book.open_book()
				get_viewport().set_input_as_handled();return
		if use_click and not held_usable(held.desktop):
			var offer:Node=get_tree().get_first_node_in_group("hand_feeding")
			if not (event.pressed and offer!=null and offer.desktop_offer()): return
			get_viewport().set_input_as_handled();return
		if use_click:
			var desk_item:Variant=held.get("desktop")
			if event.pressed and is_instance_valid(desk_item) and _item_use.wearable(desk_item):
				# AnonPony looking at a mare gives the piece; otherwise she puts it on.
				var giver:Node=get_tree().get_first_node_in_group("hand_feeding")
				if not (_pony() and giver!=null and giver.desktop_offer()):wear_outfit(desk_item)
				get_viewport().set_input_as_handled();return
			# Looking at a pony up close: offer it to her instead (world/relationships/hand_feeding.gd).
			var feeder:Node=get_tree().get_first_node_in_group("hand_feeding")
			if event.pressed and feeder!=null and feeder.desktop_offer():
				get_viewport().set_input_as_handled();return
			_desktop_eating=event.pressed;get_viewport().set_input_as_handled();return
	if customizer.opened:
		if event is InputEventMouse:
			var point:Vector3=customizer.ray_point(camera.project_ray_origin(event.position),camera.project_ray_normal(event.position))
			if event is InputEventMouseMotion and _mirror_drag:customizer.mirror.yaw-=event.relative.x*.009
			elif event is InputEventMouseButton:
				if event.button_index==MOUSE_BUTTON_LEFT:
					if event.pressed and point.is_finite():
						var pixel:=Vector2(point.x,point.y)
						_mirror_drag=Rect2(672,93,480,576).has_point(pixel)
						if not _mirror_drag:customizer.activate(pixel)
					else:_mirror_drag=false
				elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
					customizer.mirror.zoom=clampf(customizer.mirror.zoom+(-.15 if event.button_index==MOUSE_BUTTON_WHEEL_UP else .15),1.5,4.5)
			get_viewport().set_input_as_handled()
		return
	# With the lid shut the mouse keeps steering the camera, even while holding something.
	if not case.visible:return
	if event is InputEventMouseMotion:
		_mouse_position=event.position
		var hover:=_mouse_panel(event.position)
		_set_hover(case.ui.slot_at(Vector2(hover.x,hover.y)) if hover.is_finite() else -1)
		if _mouse_down and _drag_slot>=0 and event.position.distance_to(_mouse_origin)>12:
			var p:=_mouse_panel(event.position)
			if not p.is_finite() or case.ui.slot_at(Vector2(p.x,p.y))!=_drag_slot:
				take_slot("desktop",_drag_slot,camera.global_transform);_drag_slot=-1
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index==MOUSE_BUTTON_LEFT:
		_mouse_position=event.position
		var p:=_mouse_panel(event.position)
		if event.pressed:
			_mouse_down=true;_mouse_origin=event.position
			if held.has("desktop"):
				if p.is_finite() and case.amount>.95:
					var target:int=case.ui.slot_at(Vector2(p.x,p.y))
					if target>=0:_store_held("desktop",target)
					elif case.ui.STORE.has_point(Vector2(p.x,p.y)):_return_held("desktop")
				else:_drop("desktop")
			elif _desktop_pick(event.position):pass
			elif case.visible and camera.unproject_position(case.handle_world()).distance_to(event.position)<35:_moving_case=true
			elif case.visible and not case.opened:case.set_open(true)
			elif p.is_finite():
				activate(Vector2(p.x,p.y),"desktop",camera.global_transform)
				_drag_slot=case.ui.slot_at(Vector2(p.x,p.y))
		else:
			if _drag_slot==-1 and _mouse_down and held.has("desktop") and event.position.distance_to(_mouse_origin)>12:
				var target:int=case.ui.slot_at(Vector2(p.x,p.y)) if p.is_finite() else -1
				if target>=0:_store_held("desktop",target)
				else:_drop("desktop")
			_mouse_down=false;_drag_slot=-1;_moving_case=false
		get_viewport().set_input_as_handled()
func _quick_slot(slot: int) -> void:
	_desktop_part._quick_slot(slot)

## Something in hand that a click uses: food and drink to eat, an outfit to wear (the spray bottle
## and books are handled before this). Anything else lets the click reach the world. AnonPony
## cannot wear an outfit, so for her it is just a thing in hand.
func held_usable(item: Node) -> bool:
	return _item_use.held_usable(item)

## Desktop E on a thing in view: it goes straight into the briefcase (dev 2026-09-30: "picking up
## a thing with e should put it in my inventory"). What was in hand stays in hand: a hotbar item
## is put back in hand afterwards. With no room in the bag, the thing stays in hand.
func stash_take() -> bool:
	return _desktop_part.stash_take()

## The camera ray (2.5 m, world layer) on an easel's PaintPanel starts a desktop painting session.
func _desktop_easel_begin() -> bool:
	if not is_instance_valid(camera): return false
	var query := PhysicsRayQueryParameters3D.create(camera.global_position, camera.global_position - camera.global_basis.z * 2.5, 1)
	if player_body is CollisionObject3D: query.exclude = [(player_body as CollisionObject3D).get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Variant = hit.get("collider")
	if not collider is Node or not (collider as Node).has_meta("painting_easel"): return false
	var wake: Variant = (collider as Node).get_meta("painting_easel")
	return is_instance_valid(wake) and bool((wake as Node).call("desktop_begin"))

## Desktop: holding one thing and looking at another to take, E puts the held one in the bag
## first (dev 2026-09-30: the pickup must be "WAY more functional"; before this, E did nothing
## until the hand was emptied with a number key).
func can_swap_take(look: Dictionary) -> bool:
	return _desktop_part.can_swap_take(look)

func swap_take() -> bool:
	return _desktop_part.swap_take()

func _desktop_look_pick(look: Dictionary = {})->bool:
	return _desktop_part._desktop_look_pick(look)

func _unhandled_input(event: InputEvent) -> void:
	if not _desktop or case == null or not is_instance_valid(camera):return
	# A station that took a click (hold to crank) hears its release wherever the press went.
	if event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT and STATION_INPUT.engaged("desktop"):
		STATION_INPUT.offer(self,"desktop",false);return
	if not event is InputEventMouseButton or not event.pressed or event.button_index != MOUSE_BUTTON_LEFT:return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or _quick_blocked() or hand_busy("desktop"):return
	if FLIGHT_INPUT.reserves_mouse(event,player_body):return
	if is_instance_valid(player_body) and "controls_locked" in player_body and player_body.controls_locked:return
	var focus:Control=get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:return
	if not COOKING.offer(self,"desktop").is_empty():
		COOKING.activate(self,"desktop");get_viewport().set_input_as_handled();return
	if STATION_INPUT.offer(self,"desktop",true):get_viewport().set_input_as_handled();return
	var offer:Dictionary=desktop_look_target()
	if _desktop_look_pick(offer):get_viewport().set_input_as_handled()

## Shift+Q places on the visible support under the aim. Item accounting commits
## before its pose changes; a blocked/full/failed write keeps the item in hand.
func desktop_place_offer() -> Dictionary:
	return _desktop_part.desktop_place_offer()

func desktop_place() -> bool:
	return _desktop_part.desktop_place()

func _present_desktop_item(item:Node3D) -> void:
	_desktop_part._present_desktop_item(item)

func _clear_desktop_item_pose() -> void:
	_desktop_part._clear_desktop_item_pose()

func item_presentation() -> Dictionary:
	return _desktop_part.item_presentation()

## What E would pick up: {"target", "kind": "book"|"food"|"loose"} or {}. Shared by the pickup
## and the blue highlight (world/ui/interaction_hints.gd), so what glows is what E takes.
func desktop_look_target()->Dictionary:
	return _desktop_part.desktop_look_target()

func _mouse_panel(pixel: Vector2) -> Vector3:
	return _desktop_part._mouse_panel(pixel)
func _set_hover(index: int):
	return _desktop_part._set_hover(index)
func _desktop_pick(pixel: Vector2) -> bool:
	return _desktop_part._desktop_pick(pixel)
## Desktop Tab (dev 2026-10-01: "make tab pull up your wrist menu"): the wrist menu's three
## buttons float in front of the view with the mouse free; a click on one uses it, Tab or Esc
## puts it away. VR keeps the palm-to-face gesture.
var _desktop_wrist := false
var _wrist_lock_owned := false
var _wrist_mouse_before := Input.MOUSE_MODE_CAPTURED
func _toggle_desktop_wrist(open: bool) -> void:
	_wrist_part._toggle_desktop_wrist(open)

func _desktop_wrist_click(pixel: Vector2) -> void:
	_wrist_part._desktop_wrist_click(pixel)

func _exit_tree():
	_clear_desktop_item_pose()
	# Head placement reparents the display outside this runtime; retain its ownership.
	if is_instance_valid(hotbar) and hotbar.get_parent() != self: hotbar.queue_free()
	_release_magic()
	if _desktop_wrist: _toggle_desktop_wrist(false)
	if _desktop_lock_owned or _wardrobe_lock_owned:
		if is_instance_valid(player_body): player_body.controls_locked = _map_open()
		if _desktop and not _map_open(): Input.mouse_mode = _mouse_before
	_wrist_lock_owned = false; _desktop_lock_owned = false; _wardrobe_lock_owned = false
	for side in SIDES:_claim(side,false)

func setup_inspector(context:Node):
	inspector=preload("res://world/ui/profile/pony_inspector.gd").new();add_child(inspector);inspector.setup(self,context)

## The held object supplies its own compact control hint.
func interaction_hint() -> Dictionary:
	for side: String in held:
		var item: Node3D = held[side]
		if is_instance_valid(item) and item.get_meta("item_id", "") == "spray-bottle":
			return {"target": item, "text": "Click · Spray water" if side == "desktop" else "Trigger · Spray water", "point": item.global_position + Vector3.UP * .15}
		if is_instance_valid(item) and item.get_meta("item_id", "") == "goods:camera":
			return {"target": item, "text": "Click · Take photo   Hold right click · Look through" if side == "desktop" else "Eyepiece to your eye · Look through   Trigger · Take photo", "point": item.global_position + Vector3.UP * .12}
		if is_instance_valid(item) and item.get_meta("item_id", "") == "goods:easel":
			return {"target": item, "text": "Click · Unfold easel on flat ground" if side == "desktop" else "Trigger · Unfold easel on flat ground", "point": item.global_position + Vector3.UP * .15}
		if is_instance_valid(item) and item.get_meta("item_id", "") == "goods:game-board":
			return {"target": item, "text": "Click · Unfold the game board on flat ground" if side == "desktop" else "Trigger · Unfold the game board on flat ground", "point": item.global_position + Vector3.UP * .15}
		if PHOTO_JOURNAL.handles(item):
			return PHOTO_JOURNAL.on(item).hint(side)
		if LETTER_TOOL.handles(item):
			return LETTER_TOOL.on(item).hint(side)
		if NOTEBOOK_TOOL.handles(item):
			return NOTEBOOK_TOOL.on(item).hint(side)
	# The quill writes on paper held in the other hand (VR; world/letters/paper/quill_tool.gd).
	for side: String in held:
		var item: Node3D = held[side]
		if is_instance_valid(item) and item.get_meta("item_id", "") == "goods:quill":
			var quill_text := "Quill to an open letter · Speak to write" if side != "desktop" else "Hold writing paper and click it to type a letter   Q · Throw"
			return {"target": item, "text": quill_text, "point": item.global_position + Vector3.UP * .1, "outline": null}
	return {}

func _pony() -> bool:
	return _magic_part._pony()

func _pony_form() -> Node:
	return _magic_part._pony_form()


func _sync_magic() -> void:
	_magic_part._sync_magic()

func _unglow(item: Node) -> void:
	_magic_part._unglow(item)

func _release_magic() -> void:
	_magic_part._release_magic()

## Current physical hand contents only. Stored inventory and equipped clothing are
## deliberately absent; callers decide which objects the observer can actually see.
func visible_held_items() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen := {}
	for side: String in ["left", "right", "desktop"]:
		var candidate: Variant = held.get(side)
		var item: Node3D = candidate as Node3D if is_instance_valid(candidate) else null
		if is_instance_valid(item) and item.is_inside_tree() and not item.is_queued_for_deletion():
			result.append(_held_description(item, side)); seen[item.get_instance_id()] = true
		var hand: Node = hands.get(side)
		if not is_instance_valid(hand) or not "held_object" in hand: continue
		var grasped: Variant = hand.held_object
		var physical: Node3D = grasped as Node3D if is_instance_valid(grasped) else null
		if is_instance_valid(physical) and physical.is_inside_tree() and not physical.is_queued_for_deletion() and not seen.has(physical.get_instance_id()):
			result.append(_held_description(physical, side)); seen[physical.get_instance_id()] = true
	if not holding_case.is_empty() and is_instance_valid(case) and case.is_inside_tree():
		result.append({"node":case, "hand":holding_case, "id":"briefcase", "name":"a briefcase"})
	return result

func _held_description(item: Node3D, side: String) -> Dictionary:
	var id := str(item.get_meta("item_id", "")) if item.has_meta("item_id") else ""
	var definition: Dictionary = CATALOG.definition(id) if not id.is_empty() else {}
	var label := str(definition.get("name", ""))
	if label.is_empty() and item.has_meta("ai_label"): label = str(item.get_meta("ai_label"))
	if label.is_empty(): label = "an object"
	return {"node":item, "hand":side, "id":id, "name":label.left(100)}


## The stand-up key (Q by default, rebindable) gets the desktop player up from a seat, bed or ground
## posture; Q throws only on foot, or always when stand-up is bound elsewhere.
func _q_stands() -> bool:
	if not is_instance_valid(player_body): return false
	if player_body.get("seat") != null: return true
	var form: Node = get_tree().get_first_node_in_group("player_pony_form")
	return form != null and form.has_method("ground_posture") and not str(form.ground_posture()).is_empty()
