extends Node
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Physical rod adapter: E/grip takes a rod; mouse casts/lifts, wheel turns its reel.
## VR holds grip and swings while releasing trigger to cast; the free hand cranks the reel.
## AnonPony (docs/ANONPONY_DESIGN_2026_10_01.md section 9): an earth pony or pegasus holds the rod in
## her mouth; a unicorn floats it in front of her in her magic. Casting and reeling are unchanged.
const PONY_FORM := preload("res://player/pony_form.gd")
const PLAYER_MOUTH := preload("res://player/player_mouth.gd")
const UNICORN_MAGIC := preload("res://world/characters/magic/unicorn_magic.gd")
## The handle of a rod a unicorn levitates, from her eyes: a little right of centre and below.
const UNICORN_ROD := Vector3(.08, -.18, -.42)
var dock: Node3D
var inventory: Node
var rod: Node3D
var side: String = ""
var _pressed: Dictionary = {"left":true,"right":true}
var _trigger: bool = false
var _last_point: Vector3
var _speed: float = 0
var _crank_angle: float = INF
var _cast_pose: float = 0
var _reel_side: String = ""
var _magic: Node
var _magic_meshes: Array = []
var _desktop_pose_owned := false
var _desktop_helper_owned := false

func setup(place: Node3D, ui: Node) -> void:
	dock = place; inventory = ui; process_physics_priority = -65
	add_to_group("interaction_hint_sources")
	add_to_group("grab_providers")

func grab_offer(hand_side: String, sample: Dictionary) -> Dictionary:
	if not _available() or is_instance_valid(rod): return {}
	var pose: Transform3D = sample.get("pose", Transform3D.IDENTITY)
	var point: Vector3 = sample.get("grip_position", pose.origin)
	var candidate: Node3D = dock.rod_near(point)
	if candidate == null or not str(candidate.holder).is_empty(): return {}
	var hit := _hint_ray(point,candidate.global_position)
	if not hit.is_empty() and hit.get("collider") != candidate.grip: return {}
	return {"target":candidate.grip,"rod":candidate,"point":candidate.global_position,"text":hand_side.capitalize()+" grip · Take rod"}

func grab_take(hand_side: String, offer: Dictionary, _sample: Dictionary) -> bool:
	return take(offer.rod,hand_side)

## Read-only affordance; holding our own rod legitimately owns a busy hand.
func interaction_hint() -> Dictionary:
	if not _available() or not is_instance_valid(dock): return {}
	var desktop: bool = inventory._desktop
	if desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED: return {}
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return {}
	if is_instance_valid(rod):
		if str(rod.holder) != "player": return {}
		if not desktop:
			var sample: Dictionary = inventory.hand_sample(side)
			var pose: Transform3D = sample.get("pose", sample.get("aim", Transform3D.IDENTITY))
			if not sample.get("active", false) or not pose.is_finite(): return {}
		var state: String = rod.line.state
		var text: String = ""
		var point: Vector3 = rod.global_position
		match state:
			"ready": text = "[LMB] Cast" if desktop else "Hold trigger, swing rod, release trigger · Cast"
			"bite": text = "[LMB] Hook fish" if desktop else "Lift rod or press trigger · Hook fish"
			"waiting", "hooked":
				if desktop:
					text = "Mouse wheel · Reel in"
				else:
					var other: String = "right" if side == "left" else "left"
					if inventory.hand_busy(other) and _reel_side != other: return {}
					var sample: Dictionary = inventory.hand_sample(other)
					var pose: Transform3D = sample.get("pose", sample.get("aim", Transform3D.IDENTITY))
					if not sample.get("active", false) or not pose.is_finite(): return {}
					var centre: Vector3 = Vector3(.065, -.04, 0)
					if rod.to_local(pose.origin).distance_to(centre) >= .19: return {}
					point = rod.to_global(centre)
					text = other.capitalize() + " grip + turn crank · Reel in"
			"casting": text = "Casting · [E/Q] Return rod" if desktop else "Casting · Release grip to return rod"
		if text.is_empty(): return {}
		if desktop and state != "casting": text += "   [E/Q] Return rod"
		return {"target":rod.grip, "text":text, "point":point, "collider":rod.grip}
	if desktop:
		if inventory.hand_busy("desktop"): return {}
		var camera: Camera3D = inventory.camera
		var hit: Dictionary = _hint_ray(camera.global_position, camera.global_position-camera.global_basis.z*2.2)
		var collider: Node = hit.get("collider") as Node
		if collider == null or not collider.has_meta("fishing_rod"): return {}
		var candidate: Node3D = collider.get_meta("fishing_rod") as Node3D
		if not is_instance_valid(candidate) or not str(candidate.holder).is_empty(): return {}
		return {"target":candidate.grip, "text":"[E] Take rod", "point":hit.position, "collider":collider}
	if inventory.get("grab_router") != null: return {}
	for hand_side: String in ["right", "left"]:
		if inventory.hand_busy(hand_side): continue
		var sample: Dictionary = inventory.hand_sample(hand_side)
		var pose: Transform3D = sample.get("pose", sample.get("aim", Transform3D.IDENTITY))
		if not sample.get("active", false) or not pose.is_finite(): continue
		var candidate: Node3D = dock.rod_near(pose.origin)
		if candidate == null: continue
		var hit: Dictionary = _hint_ray(pose.origin, candidate.global_position)
		if not hit.is_empty() and hit.get("collider") != candidate.grip: continue
		return {"target":candidate.grip, "text":hand_side.capitalize()+" grip · Take rod", "point":candidate.global_position, "collider":candidate.grip}
	return {}

func _hint_ray(from: Vector3, to: Vector3) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, to, 3)
	if inventory.player_body is CollisionObject3D: query.exclude = [inventory.player_body.get_rid()]
	return inventory.camera.get_world_3d().direct_space_state.intersect_ray(query)

func _available() -> bool:
	if not is_instance_valid(inventory) or not is_instance_valid(inventory.camera): return false
	if inventory.player_body.controls_locked: return false
	if get_tree().paused or inventory.case.visible or inventory.customizer.opened or inventory._map_open(): return false
	if inventory._desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(inventory.player_body): return false
		var focus: Control = get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit: return false
		var owner: Variant = inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
		if is_instance_valid(owner) and owner != self: return false
	return true

func _physics_process(delta: float) -> void:
	if not is_instance_valid(inventory): return
	if is_instance_valid(rod) and not _available(): release()
	if inventory._desktop:
		if is_instance_valid(rod):
			_cast_pose = move_toward(_cast_pose,0,delta*3)
			var hold: Transform3D = Transform3D(Basis(Vector3.RIGHT,-.72-_cast_pose),Vector3(.25,-.30,-.47))
			var form: Node = PONY_FORM.find(get_tree())
			if form == null or not is_instance_valid(form.get("avatar")):
				# His hand's reach follows Anon's height (player_mouth.gd human_scale).
				rod.global_transform = PLAYER_MOUTH.hold_transform(inventory.camera,hold)
			elif form.is_unicorn():
				rod.global_transform = inventory.camera.global_transform*Transform3D(hold.basis,UNICORN_ROD)
				_glow(form)
			else:
				# The handle at her muzzle, the rod rising at the same angle a hand holds it.
				rod.global_transform = PLAYER_MOUTH.hold_transform(inventory.camera,hold)*Transform3D(hold.basis,Vector3.ZERO)
			_present_desktop()
		return
	for hand_side: String in ["left","right"]:
		var sample: Dictionary = inventory.hand_sample(hand_side)
		var pose: Transform3D = sample.get("pose",sample.get("aim",Transform3D.IDENTITY))
		var active: bool = _available() and sample.get("active",false) and pose.is_finite()
		if not active and _reel_side==hand_side: _release_reel()
		var down: bool = active and float(sample.get("grip",0))>(.25 if side == hand_side or _pressed[hand_side] else .45)
		if is_instance_valid(rod) and side==hand_side:
			if not active or not down: release()
			else:
				_speed = pose.origin.distance_to(_last_point)/maxf(delta,.001); _last_point = pose.origin
				rod.global_transform = pose*Transform3D(Basis(Vector3.RIGHT,-PI*.5),Vector3.ZERO)
				var trigger: bool = float(sample.get("trigger",0))>.6
				if _trigger and not trigger and rod.line.state=="ready" and _speed>.45:
					rod.cast(-pose.basis.z,clampf(_speed*.45,.7,1.3))
				elif trigger and not _trigger and rod.line.state=="bite": rod.line.hook()
				_trigger = trigger
		elif inventory.get("grab_router") == null and active and down and not _pressed[hand_side] and not is_instance_valid(rod) and not inventory.hand_busy(hand_side):
			var candidate: Node3D = dock.rod_near(pose.origin)
			if candidate != null: take(candidate,hand_side)
		elif active and is_instance_valid(rod) and hand_side!=side and (not inventory.hand_busy(hand_side) or _reel_side==hand_side):
			var local: Vector3 = rod.to_local(pose.origin)
			# Reel spindle is along local X, below the grip; crank circles in its Y/Z plane.
			var centre: Vector3 = Vector3(.065,-.04,0)
			if down and local.distance_to(centre)<.19:
				_claim_reel(hand_side)
				var angle: float = atan2(local.z-centre.z,local.y-centre.y)
				if is_finite(_crank_angle):
					var turn: float = absf(wrapf(angle-_crank_angle,-PI,PI))
					if turn<.9: rod.reel(turn*1.2/TAU)
				_crank_angle=angle
			else: _release_reel()
		_pressed[hand_side]=down if active else true

func take(candidate: Node3D, hand_side: String) -> bool:
	if not _available() or is_instance_valid(rod) or inventory.hand_busy(hand_side): return false
	if not candidate.take("player"): return false
	rod=candidate;side=hand_side;_last_point=rod.global_position;_trigger=true
	if side=="desktop":
		inventory.set_meta("desktop_activity_owner",self)
		_present_desktop()
	var excludes: Array[RID] = []
	if inventory.player_body is CollisionObject3D: excludes.append(inventory.player_body.get_rid())
	rod.player_excludes = excludes
	var hand: Node = inventory.hands.get(side)
	if is_instance_valid(hand): hand.set_meta("fishing_grip",self);hand.set_meta("inventory_busy",true)
	inventory._haptic(side); return true

func release() -> void:
	_release_reel()
	_unglow()
	if is_instance_valid(rod): rod.put_back()
	if is_instance_valid(inventory):
		if inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self:
			_clear_desktop_pose()
			inventory.remove_meta("desktop_activity_owner")
		var hand: Node = inventory.hands.get(side)
		if is_instance_valid(hand) and hand.has_meta("fishing_grip") and hand.get_meta("fishing_grip")==self:
			hand.remove_meta("fishing_grip");hand.remove_meta("inventory_busy")
	rod=null;side="";_crank_angle=INF
	_desktop_pose_owned=false;_desktop_helper_owned=false

func _claim_reel(hand_side: String) -> void:
	if _reel_side==hand_side:return
	_release_reel()
	var hand: Node = inventory.hands.get(hand_side)
	if is_instance_valid(hand):
		hand.set_meta("fishing_reel",self);hand.set_meta("inventory_busy",true)
	_reel_side=hand_side

func _release_reel() -> void:
	if is_instance_valid(inventory):
		var hand: Node = inventory.hands.get(_reel_side)
		if is_instance_valid(hand) and hand.has_meta("fishing_reel") and hand.get_meta("fishing_reel")==self:
			hand.remove_meta("fishing_reel");hand.remove_meta("inventory_busy")
	_reel_side="";_crank_angle=INF

func _input(event: InputEvent) -> void:
	if is_instance_valid(inventory) and FLIGHT_INPUT.reserves_mouse(event,inventory.player_body): return
	if not is_instance_valid(inventory) or not inventory._desktop or not _available(): return
	if Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:return
	var focus: Control=get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:return
	if is_instance_valid(rod):
		if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_E,KEY_Q]:
			release();get_viewport().set_input_as_handled()
		elif event is InputEventKey and event.physical_keycode in [KEY_1,KEY_2,KEY_3,KEY_4,KEY_5,KEY_G]:
			get_viewport().set_input_as_handled()
		elif event is InputEventMouseButton and event.pressed:
			if event.button_index==MOUSE_BUTTON_LEFT:
				if rod.line.state=="bite":rod.line.hook();_cast_pose=-.4
				elif rod.line.state=="ready":rod.cast(-inventory.camera.global_basis.z);_cast_pose=.6
				get_viewport().set_input_as_handled()
			elif event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN]:
				rod.reel(.22);get_viewport().set_input_as_handled()
		return
	if event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_E:
		if inventory.hand_busy("desktop"):return
		var camera: Camera3D=inventory.camera
		var query: PhysicsRayQueryParameters3D=PhysicsRayQueryParameters3D.create(camera.global_position,camera.global_position-camera.global_basis.z*2.2,3)
		if inventory.player_body is CollisionObject3D:query.exclude=[inventory.player_body.get_rid()]
		var hit: Dictionary=camera.get_world_3d().direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.collider.has_meta("fishing_rod") and take(hit.collider.get_meta("fishing_rod"),"desktop"):
			get_viewport().set_input_as_handled()

## The levitated rod's model glows and the horn stays lit, through PonyForm.magic(), which keeps
## the horn aura out of her own view.
func _glow(form: Node) -> void:
	if is_instance_valid(_magic) or not is_instance_valid(rod): return
	var magic: Node = form.magic()
	if magic == null: return
	var model: Variant = rod.get("visual")
	_magic = magic
	_magic_meshes = magic.glow_object(model if is_instance_valid(model) else rod)
	magic.hold(true)

func _unglow() -> void:
	UNICORN_MAGIC.unglow_object(_magic_meshes)
	if is_instance_valid(_magic): _magic.hold(false)
	_magic = null; _magic_meshes = []

func _present_desktop() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	if side != "desktop" or not is_instance_valid(rod) or not is_instance_valid(visual): return
	if not inventory.has_meta("desktop_activity_owner") or inventory.get_meta("desktop_activity_owner") != self: return
	visual.set_hold_target("right", rod.global_transform, "hold"); _desktop_pose_owned = true
	if rod.line.state in ["waiting", "hooked"]:
		var crank: Transform3D = rod.global_transform
		crank.origin = rod.to_global(Vector3(.065, -.04, 0))
		visual.set_hold_target("left", crank, "hold"); _desktop_helper_owned = true
	elif _desktop_helper_owned:
		visual.clear_hold_target("left"); _desktop_helper_owned = false

func _clear_desktop_pose() -> void:
	var visual: Node = inventory.get("desktop_presentation") as Node
	if not is_instance_valid(visual): return
	if _desktop_pose_owned: visual.clear_hold_target("right")
	if _desktop_helper_owned: visual.clear_hold_target("left")

func cancel_desktop_activity() -> void:
	if side == "desktop": release()

func presentation() -> Dictionary:
	if side != "desktop" or not is_instance_valid(rod): return {}
	return {"action": "hold", "held": rod, "target": rod.grip, "point": rod.global_position,
		"normal": -rod.global_basis.z, "helper": rod.line.state in ["waiting", "hooked"], "progress": 0.0}

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(inventory) and inventory._desktop:
		cancel_desktop_activity()

func _exit_tree() -> void:release()
