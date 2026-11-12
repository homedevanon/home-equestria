extends Node
## Grab a rope and pull down; tilt the helm in the direction of travel.
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
var ship:Node3D
var inventory:Node
var held:Dictionary={}
var pressed:Dictionary={"left":true,"right":true}
var desktop_aim:=Vector2.ZERO
var _locked:=false
var _avatar:Node
var _desktop_pose_owned:=false
var _desktop_helper_owned:=false
func setup(vehicle:Node3D,ui:Node)->void:
	ship=vehicle;inventory=ui;process_physics_priority=-90
	add_to_group("interaction_hint_sources")
	add_to_group("grab_providers")
	var root:Node=ui.player_body.get_parent() if not ui._desktop else ui.player_body
	_avatar=root.find_child("AnonBody",true,false)
func available()->bool:
	if not is_instance_valid(inventory) or not is_instance_valid(ship) or not is_instance_valid(inventory.camera):return false
	if get_tree().paused or _menu_open():return false
	if inventory.player_body.controls_locked and not _locked:return false
	if inventory._desktop:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED or FLIGHT_INPUT.mouse_banking(inventory.player_body):return false
		var owner:Variant=inventory.get_meta("desktop_activity_owner") if inventory.has_meta("desktop_activity_owner") else null
		if is_instance_valid(owner) and owner!=self:return false
	return true
func _menu_open()->bool:
	if inventory.case.visible or inventory.customizer.opened or inventory._map_open():return true
	var inspector:Node=inventory.get("inspector") as Node
	if is_instance_valid(inspector) and inspector.get("active")==true:return true
	var focus:Control=get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:return true
	var host:Node=ship.get("game")
	if is_instance_valid(host):
		for key:String in ["pause_menu","settings_menu","save_menu"]:
			if not key in host:continue
			var menu:Variant=host.get(key)
			if is_instance_valid(menu) and "opened" in menu and menu.opened:return true
	return false
func _point(sample:Dictionary)->Vector3:
	var pose:Transform3D=sample.get("pose",sample.get("aim",Transform3D.IDENTITY))
	return sample.get("grip_position",pose.origin) if sample.get("active",false) and pose.is_finite() else Vector3.INF
func grab_offer(side:String,sample:Dictionary)->Dictionary:
	if not available() or held.has(side):return {}
	var at:=_point(sample)
	if not at.is_finite():return {}
	var target:=nearby(at)
	if target==null:return {}
	for entry:Dictionary in held.values():
		if entry.node==target:return {}
	if target.name=="GateBell":
		if not ship.gate_open and not ship.can_open_gate():return {}
	elif not ship.holds_player(inventory.player_body):return {}
	return {"target":target,"point":_rope_point(target,at),"text":_gate_text("Grip ·") if target.name=="GateBell" else "Grip and pull · "+String(target.name)}
func grab_take(side:String,offer:Dictionary,sample:Dictionary)->bool:
	var pose:Transform3D=sample.get("pose",Transform3D.IDENTITY)
	return take(side,offer.target,pose.origin,_point(sample))
func nearby(at:Vector3)->Node3D:
	var nearest:Node3D;var distance:=.22
	for name:String in ["Lift","Vent","Helm","GateBell"]:
		var control:Node3D=ship.get_node(name)
		# A rope is gripped anywhere from its handle up to the pulley, a little tighter than the handle.
		var d:=minf(at.distance_to(control.global_position),at.distance_to(_rope_point(control,at))+.08)
		if d<distance:nearest=control;distance=d
	# The gate itself opens and closes too, not only its bell (dev 2026-09-28: "can't open the
	# door to the hot air balloon"): grip anywhere near its top rail or panel.
	var gate:Node3D=ship.get_node_or_null("Gate") as Node3D
	if nearest==null and gate!=null:
		for local:Vector3 in [Vector3(.55,1.14,0),Vector3(.55,.7,0),Vector3(.95,.9,0)]:
			if at.distance_to(gate.global_transform*local)<.3:return ship.get_node("GateBell")
	return nearest
## Closest point of a control's rope (handle up to its pulley); the handle itself for helm and bell.
func _rope_point(control:Node3D,at:Vector3)->Vector3:
	var pulley:Node3D=ship.get_node_or_null(String(control.name)+"Pulley") as Node3D
	if pulley==null or not at.is_finite():return control.global_position
	return Geometry3D.get_closest_point_to_segment(at,control.global_position,pulley.global_position)
## Where the hand closes on a held control, following the handle as the rope runs down.
func _grip_point(row:Dictionary)->Vector3:
	return (row.node as Node3D).to_global(row.get("anchor",Vector3.ZERO))
func aimed()->Node3D:
	var camera:Camera3D=inventory.camera
	var q:=PhysicsRayQueryParameters3D.create(camera.global_position,camera.global_position-camera.global_basis.z*2.2,1|ship.CONTROL_LAYER)
	if inventory.player_body is CollisionObject3D:q.exclude=[inventory.player_body.get_rid()]
	var hit:Dictionary=camera.get_world_3d().direct_space_state.intersect_ray(q)
	var node:Node3D=hit.get("collider") as Node3D
	# From inside the basket the gate panel stands in front of its catch (dev 2026-09-28: "i cant
	# open the balloon door from the inside"): aiming at the gate itself works the catch.
	if node!=null and node.get_parent()==ship and String(node.name)=="Gate":return ship.get_node("GateBell")
	return node if node!=null and node.get_parent()==ship and String(node.name) in ["Lift","Vent","Helm","GateBell"] else null
func take(side:String,control:Node3D,at:Vector3,palm:=Vector3.INF)->bool:
	if not available() or (inventory.hand_busy(side) and not inventory.equipped_only(side)):return false
	for entry:Dictionary in held.values():
		if entry.node==control:return false
	if control.name=="GateBell":return ship.toggle_gate()
	if not ship.holds_player(inventory.player_body):return false
	# An equipped hotbar item goes back to its slot when the hand takes a rope or the helm.
	if inventory.equipped_only(side) and not inventory._store_held(side):return false
	if inventory.hand_busy(side):return false
	var anchor:Vector3=control.to_local(_rope_point(control,palm)) if palm.is_finite() else Vector3.ZERO
	held[side]={"node":control,"start":ship.to_local(at),"anchor":anchor,"camera_basis":ship.global_basis.inverse()*inventory.camera.global_basis}
	if side=="desktop":
		inventory.set_meta("desktop_activity_owner",self);inventory.player_body.controls_locked=true;_locked=true
		_present_desktop()
	else:
		var hand:Node=inventory.hands.get(side)
		if is_instance_valid(hand):hand.set_meta("balloon_control",self);hand.set_meta("inventory_busy",true)
	inventory._haptic(side);return true
func grip_transform(side:String)->Variant:
	if not held.has(side):return null
	var sample:Dictionary=inventory.hand_sample(side)
	var pose:Transform3D=sample.get("pose",sample.get("aim",Transform3D.IDENTITY))
	pose.origin=_grip_point(held[side])
	return pose
func release(side:String)->void:
	if not held.has(side):return
	held.erase(side)
	if side=="desktop":
		var owns:bool=inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self
		if owns:
			_clear_desktop_pose()
			inventory.remove_meta("desktop_activity_owner")
		_desktop_pose_owned=false;_desktop_helper_owned=false
		# Menus release us before snapshotting their lock. A late cancellation must
		# still preserve a lock already acquired by another owner.
		if _locked and owns and not _menu_open() and is_instance_valid(inventory.player_body):inventory.player_body.controls_locked=false
		_locked=false
		desktop_aim=Vector2.ZERO
	else:
		var hand:Node=inventory.hands.get(side)
		if is_instance_valid(hand) and hand.has_meta("balloon_control") and hand.get_meta("balloon_control")==self:
			hand.remove_meta("balloon_control");hand.remove_meta("inventory_busy")
		if is_instance_valid(_avatar):_avatar.set_hand_override(side,null)
func _present_desktop()->void:
	var visual:Node=inventory.get("desktop_presentation") as Node
	if not held.has("desktop") or not is_instance_valid(visual):return
	if not inventory.has_meta("desktop_activity_owner") or inventory.get_meta("desktop_activity_owner")!=self:return
	var control:Node3D=held.desktop.node
	var frame:Transform3D=control.global_transform.orthonormalized()
	var helper:bool=control.name=="Helm"
	var across:Vector3=control.global_basis.x.normalized()
	if across.dot(inventory.camera.global_basis.x)<0.0:across=-across
	if helper:frame.origin+=across*.10
	visual.set_hold_target("right",frame,"hold");_desktop_pose_owned=true
	if helper:
		frame.origin=control.global_position-across*.10
		visual.set_hold_target("left",frame,"hold");_desktop_helper_owned=true
	elif _desktop_helper_owned:
		visual.clear_hold_target("left");_desktop_helper_owned=false
func _clear_desktop_pose()->void:
	var visual:Node=inventory.get("desktop_presentation") as Node
	if not is_instance_valid(visual):return
	if _desktop_pose_owned:visual.clear_hold_target("right")
	if _desktop_helper_owned:visual.clear_hold_target("left")
func owns_control_lock()->bool:
	return _locked and held.has("desktop") and is_instance_valid(inventory) and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self
func cancel_desktop_activity()->void:
	release("desktop")
	if is_instance_valid(ship):ship.set_controls(0,0,Vector2.ZERO)
func release_all()->void:
	for side:String in held.keys():release(side)
	if is_instance_valid(ship):ship.set_controls(0,0,Vector2.ZERO)
## Perf 0.1.0: with nothing held and the player's view farther than this from the basket no hand
## can reach a rope (reach is under a metre from the eye); the tick only re-zeroed controls that
## are already zero, so it is skipped. Grip memory resets exactly as when unavailable.
## INF: always run the full tick.
const FAR_SKIP:=12.0
func _physics_process(_delta:float)->void:
	if held.is_empty() and is_instance_valid(ship) and is_instance_valid(inventory) and is_instance_valid(inventory.camera) \
			and ship.lift==0.0 and ship.vent==0.0 and ship.steering==Vector2.ZERO \
			and inventory.camera.global_position.distance_squared_to(ship.global_position)>FAR_SKIP*FAR_SKIP:
		# Far and idle: keep the existing all-pressed table instead of a new one every tick.
		if not (pressed.get("left")==true and pressed.get("right")==true):pressed={"left":true,"right":true}
		return
	if not available():release_all();pressed={"left":true,"right":true};return
	var up:=0.0;var down:=0.0;var aim:=Vector2.ZERO
	if inventory._desktop:
		if held.has("desktop"):
			var control:Node3D=held.desktop.node
			if inventory.camera.global_position.distance_to(control.global_position)>2.4 or Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:release_all();return
			_present_desktop()
			match String(control.name):
				"Helm":
					var axes:Basis=held.desktop.camera_basis
					var direction:Vector3=axes.x*desktop_aim.x+axes.z*desktop_aim.y
					aim=Vector2(direction.x,direction.z).limit_length(1)
					up=1.0 if Input.is_physical_key_pressed(KEY_SPACE) else 0.0
					down=1.0 if Input.is_physical_key_pressed(KEY_CTRL) else 0.0
				"Lift":up=1.0
				"Vent":down=1.0
	else:
		for side:String in ["left","right"]:
			var sample:Dictionary=inventory.hand_sample(side);var at:=_point(sample)
			var grip:bool=at.is_finite() and float(sample.get("grip",0))>(.25 if held.has(side) or pressed[side] else .45)
			if held.has(side):
				var row:Dictionary=held[side]
				if not grip or at.distance_to(_grip_point(row))>.85:release(side)
				else:
					var tracking:Transform3D=sample.get("pose",Transform3D.IDENTITY)
					var motion:Vector3=ship.to_local(tracking.origin)-Vector3(row.start)
					match String(row.node.name):
						"Lift":up=clampf(-motion.y/.3,0,1)
						"Vent":down=clampf(-motion.y/.3,0,1)
						"Helm":aim=Vector2(motion.x,motion.z).limit_length(.25)/.25
					if is_instance_valid(_avatar):
						var pose:Transform3D=sample.get("pose",sample.get("aim",Transform3D.IDENTITY));pose.origin=_grip_point(row);_avatar.set_hand_override(side,pose)
			elif inventory.get("grab_router")==null and grip and not pressed[side] and (not inventory.hand_busy(side) or inventory.equipped_only(side)):
				var control:Node3D=nearby(at)
				if control!=null:take(side,control,at,at)
			pressed[side]=grip if at.is_finite() else true
	ship.set_controls(up,down,aim)
func _input(event:InputEvent)->void:
	if not is_instance_valid(inventory) or not inventory._desktop or not available():return
	if Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:return
	var focus:Control=get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:return
	if held.has("desktop"):
		if event is InputEventMouseMotion:
			desktop_aim=(desktop_aim+event.relative*.006).limit_length(1);get_viewport().set_input_as_handled()
		elif (event is InputEventKey and event.pressed and not event.echo and event.physical_keycode in [KEY_E,KEY_Q,KEY_ESCAPE]) or (event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT):
			release_all()
			if not event is InputEventKey or event.physical_keycode!=KEY_ESCAPE:get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.physical_keycode==KEY_E:
		var control:=aimed()
		if control!=null and take("desktop",control,control.global_position):get_viewport().set_input_as_handled()
func _unhandled_input(event:InputEvent)->void:
	if not is_instance_valid(inventory) or not inventory._desktop or not available() or held.has("desktop"):return
	if event is InputEventMouseButton and event.pressed and event.button_index==MOUSE_BUTTON_LEFT:
		var control:Node3D=aimed()
		if control!=null and take("desktop",control,control.global_position):get_viewport().set_input_as_handled()
func presentation()->Dictionary:
	if not held.has("desktop"):return {}
	var control:Node3D=held.desktop.node
	if not is_instance_valid(control):return {}
	return {"action":"reach","held":null,"target":control,"point":control.global_position,
		"normal":control.global_basis.z,"helper":control.name=="Helm","progress":0.0}
func interaction_hint()->Dictionary:
	if not available():return {}
	var control:Node3D
	var text:=""
	if inventory._desktop:
		if Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:return {}
		if not held.has("desktop") and inventory.hand_busy("desktop") and not inventory.equipped_only("desktop"):return {}
		control=held.desktop.node if held.has("desktop") else aimed()
		if control!=null and control.name!="GateBell" and not ship.holds_player(inventory.player_body):return {}
		if control!=null:
			# Held inventory use gets first click; E can durably stow an equipped item.
			var prefix:String="[E]" if inventory.hand_busy("desktop") else "[LMB/E]"
			text=_gate_text(prefix) if control.name=="GateBell" else prefix+" Grab "+String(control.name)
			if held.has("desktop"):text="Mouse · steer | Space · rise | Ctrl · descend | LMB/E/Q · release" if control.name=="Helm" else "Pulling "+String(control.name)+" · [LMB/E/Q] release"
	else:
		for side:String in ["right","left"]:
			if inventory.get("grab_router")!=null and not held.has(side):continue
			var at:=_point(inventory.hand_sample(side))
			if not at.is_finite():continue
			control=held[side].node if held.has(side) else (nearby(at) if not inventory.hand_busy(side) or inventory.equipped_only(side) else null)
			if control!=null:
				text=_gate_text("Grip ·") if control.name=="GateBell" else ("Grip and tilt · steer" if control.name=="Helm" else "Grip and pull down · "+String(control.name));break
	if control==null:return {}
	return {"target":control,"point":control.global_position,"collider":control,"text":text}
## The gate only opens resting on ground or cloud; say so instead of silently refusing.
func _gate_text(prefix:String)->String:
	if ship.gate_open:return prefix+" Close gate"
	return prefix+" Open gate" if ship.can_open_gate() else "Land to open the gate"
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and is_instance_valid(inventory) and inventory._desktop:
		cancel_desktop_activity()

func _exit_tree()->void:
	if is_instance_valid(inventory):release_all()
