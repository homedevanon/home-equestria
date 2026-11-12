extends Node3D
const FLIGHT_INPUT := preload("res://player/wing_flight.gd")
## Shared two-hand adapter. Desktop C starts/ends; drag with LMB/RMB, wheel adjusts depth.
## Cuddles happen on a bed or couch only (dev 2026-09-28): a manual start (C, VR grip) and its
## hint need a mare lying there with Anon (couch_cuddle), and she joins him by her own choice.
## AnonPony has no arms to pose a cuddle with (docs/ANONPONY_DESIGN_2026_10_01.md section 10).
const PLAYER_FORM:=preload("res://world/life/player_form.gd")
var game:Node
var camera:Camera3D
var body:Node3D
var inventory:Node
var grabber:Node
var sessions:Array[Node]=[]
var current:Node
var _pending:Node
var _pending_time:=0.0
var _scan:=0.0
var _xr:=false
var _previous:Dictionary={"left":false,"right":false}
var _desktop:Dictionary={}
var _drag_side:=""
var _hover:Dictionary={}
var _marker:MeshInstance3D

func setup(host:Node)->void:
	game=host;camera=host._find_camera(host.player);inventory=host.inventory;grabber=host.grabber
	body=host.player.get_node_or_null("Body") if host.xr_active else host.player
	_xr=host.xr_active
	process_physics_priority=-25
	add_to_group("interaction_hint_sources")
	add_to_group("cuddle_input")
	_marker=MeshInstance3D.new();var mesh:=SphereMesh.new();mesh.radius=.022;mesh.height=.044;_marker.mesh=mesh
	var material:=StandardMaterial3D.new();material.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED;material.albedo_color=Color(.2,.7,1)
	_marker.material_override=material;_marker.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_marker);_marker.hide()

func add_pony(actor:CharacterBody3D)->Node:
	var existing:=actor.get_node_or_null("CuddleSession")
	if existing!=null:return existing
	var session:=preload("res://world/relationships/cuddle/session.gd").new();session.name="CuddleSession";session.mare=actor
	actor.add_child(session);sessions.append(session)
	return session

func holding(side:String)->bool:
	return is_instance_valid(current) and current.grips.has(side)

func grip_transform(side:String)->Transform3D:
	var hand:Node3D=grabber._hands.get(side)
	return Transform3D(hand.global_basis.orthonormalized() if hand!=null else camera.global_basis.orthonormalized(),current.grip_point(side))

func _free(side:String)->bool:
	if not is_instance_valid(inventory):return true
	if side=="desktop" and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self:return true
	return not inventory.hand_busy(side)

func _available()->bool:
	if is_inside_tree() and PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree())):return false
	return is_instance_valid(camera) and is_instance_valid(body) and body.get("controls_locked")!=true and body.get("flying")!=true and not body.get_meta("knocked_down",false)

func _physics_process(delta:float)->void:
	if not _available():
		if not _released():_release()
		return
	if not _xr and Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:
		if not _released():_release()
		return
	if is_instance_valid(current) and (not current.enabled or body.get("velocity") is Vector3 and Vector3(body.velocity).length()>.3):
		current.end();_release();current=null
	if is_instance_valid(_pending):
		_pending_time-=delta
		if _pending_time<=0 or _pending.mare.global_position.distance_to(body.global_position)>2.5:_pending=null
		elif _pending.mare.posture_status().settled:
			if _pending.begin(body):current=_pending
			_pending=null
	_scan-=delta
	if _scan<=0:
		_scan=.25
		# Check the Variant before any Node conversion; freed objects cannot enter a typed lambda.
		for i in range(sessions.size() - 1, -1, -1):
			if not is_instance_valid(sessions[i]): sessions.remove_at(i)
			elif sessions[i].is_queued_for_deletion(): sessions.remove_at(i)
		if not is_instance_valid(current):
			for session:Node in sessions:
				if not session.mare.get_meta("couch_cuddle",false) or not session.can_begin(body):continue
				var seat:Node3D=body.get("seat") as Node3D
				var couch:Node3D=seat.get_meta("couch") if seat!=null and seat.has_meta("couch") else null
				if session.begin(body,couch):current=session;break
	_hover={};_marker.hide()
	if _xr:
		for side:String in ["left","right"]:_hand(side)
	elif is_instance_valid(current):
		for side:String in _desktop.keys():
			if current.grips.has(side):current.guide(side,Transform3D(camera.global_basis.orthonormalized(),_desktop[side]))
		_hover=current.pick_ray(camera.global_position,-camera.global_basis.z)
	else:
		var candidate:=_nearest()
		if candidate!=null:_hover={"point":candidate.mare.listen_point(),"id":"cuddle","session":candidate}
	if not _hover.is_empty():_marker.global_position=_hover.point;_marker.show()

func _hand(side:String)->void:
	if not is_instance_valid(grabber):return
	var hand:Node3D=grabber._hands.get(side)
	var tracker:Node3D=grabber._controllers.get(side)
	var tracked:bool=hand!=null and tracker!=null and (not tracker.has_method("get_is_active") or tracker.get_is_active())
	var pressed:bool=tracked and grabber._grip_pressed(side)
	if not pressed and holding(side):current.release(side)
	if not tracked:_previous[side]=true;return # Require release after tracking returns.
	var at:Transform3D=tracker.global_transform.orthonormalized()
	if holding(side):current.guide(side,at)
	elif is_instance_valid(current):
		var hit:Dictionary=current.pick(hand.global_position,.06)
		if not hit.is_empty():
			_hover=hit
			if pressed and not _previous[side] and _free(side):current.take(side,hit,at)
	elif pressed and not _previous[side] and _free(side):
		# Ground/bed sessions require an already-settled pony; ordinary standing pickup stays intact.
		for i in sessions.size():
			if not is_instance_valid(sessions[i]) or sessions[i].is_queued_for_deletion():continue
			var session:Node=sessions[i]
			if not session.mare.get_meta("couch_cuddle",false) or not session.can_begin(body):continue
			var hit:Dictionary=session.pick(hand.global_position,.04)
			if not hit.is_empty() and session.begin(body):
				current=session;current.take(side,hit,at);break
	_previous[side]=pressed

## Ponies lying with Anon on a sofa or bed (couch.gd and shared_bed.gd add them to this group
## with their couch_cuddle meta). The per-tick hover below looks only at them instead of every
## pony's session (W2 perf pass: 45 sessions a tick on desktop). Rollback: READY_SCAN = false.
const READY_GROUP:=&"couch_cuddle"
const READY_SCAN:=true

func _nearest()->Node:
	var winner:Node;var gap:=2.2
	var pool:Array=sessions
	if READY_SCAN and is_inside_tree():
		pool=[]
		for mare:Node in get_tree().get_nodes_in_group(READY_GROUP):
			var own:Node=mare.get_node_or_null(^"CuddleSession")
			if own!=null and sessions.has(own):pool.append(own)
	for i in pool.size():
		if not is_instance_valid(pool[i]) or pool[i].is_queued_for_deletion():continue
		var session:Node=pool[i]
		if not session.mare.get_meta("couch_cuddle",false) or not session.willing():continue
		var actor:Node3D=session.mare
		var point:Vector3=actor.listen_point();var distance:=camera.global_position.distance_to(point)
		if distance>gap or (-camera.global_basis.z).dot((point-camera.global_position).normalized())<.8:continue
		if not session.visible(camera.global_position,point):continue
		winner=session;gap=distance
	return winner

func _input(event:InputEvent)->void:
	if event is InputEventKey and preload("res://world/ui/typing_guard.gd").active(): return  # typing never drives the game
	if FLIGHT_INPUT.reserves_mouse(event,body): return
	if _xr or not _available():return
	if event is InputEventKey and event.physical_keycode==KEY_C and event.pressed and not event.echo:
		if Input.mouse_mode!=Input.MOUSE_MODE_CAPTURED:return
		if is_instance_valid(current):current.end();_release();current=null
		else:
			var candidate:=_nearest()
			if candidate!=null:
				if candidate.can_begin(body):candidate.begin(body);current=candidate
				elif not candidate.mare.is_held() and candidate.mare.grounded() and candidate.mare.posture_status().requested=="stand":
					var nav:Node=candidate.mare.get_node_or_null("Navigator")
					if nav!=null:nav.stay()
					if candidate.mare.request_posture("lie_down"):_pending=candidate;_pending_time=5.0
		get_viewport().set_input_as_handled();return
	if not is_instance_valid(current):return
	if event is InputEventMouseButton:
		var side:String="left" if event.button_index==MOUSE_BUTTON_LEFT else "right"
		if event.button_index in [MOUSE_BUTTON_LEFT,MOUSE_BUTTON_RIGHT]:
			if not event.pressed:
				current.release(side);_desktop.erase(side)
				if _desktop.is_empty():_unclaim()
			elif Input.mouse_mode==Input.MOUSE_MODE_CAPTURED and _free("desktop") and _desktop.is_empty():
				# Desktop has one directed grip. The other Anon hand supports the pose visually.
				var hit:Dictionary=current.pick_ray(camera.global_position,-camera.global_basis.z)
				if not hit.is_empty():
					var xf:=Transform3D(camera.global_basis.orthonormalized(),hit.point)
					if current.take(side,hit,xf):
						_desktop[side]=hit.point;_drag_side=side
						if is_instance_valid(inventory):inventory.set_meta("desktop_activity_owner",self)
			get_viewport().set_input_as_handled()
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP,MOUSE_BUTTON_WHEEL_DOWN] and _desktop.has(_drag_side):
			_desktop[_drag_side]+=camera.global_basis.z*(.035 if event.button_index==MOUSE_BUTTON_WHEEL_DOWN else -.035)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _desktop.has(_drag_side):
		_desktop[_drag_side]+=camera.global_basis.x*event.relative.x*.002-camera.global_basis.y*event.relative.y*.002
		get_viewport().set_input_as_handled()

func desktop_presentation() -> Dictionary:
	if _xr or not is_instance_valid(current) or _desktop.is_empty():return {}
	return {"action":"cuddle","point":current.grip_point(_drag_side),"normal":-camera.global_basis.z,
		"target":current.mare,"helper":true,"progress":1.0,"held":null}

func interaction_hint()->Dictionary:
	if not is_instance_valid(_marker) or not _marker.visible:return {}
	var text:String=("Grip + trigger · Pose " if _xr else "Drag · Pose ")+str(_hover.get("id","")).replace("_"," ")
	if not is_instance_valid(current):text="C · Settle together"
	elif not _xr:text+=" · C to finish"
	return {"target":_marker,"point":_marker.global_position,"text":text}

func _release()->void:
	if is_instance_valid(current):current.release_all()
	_unclaim()
	_previous={"left":true,"right":true}
	_desktop.clear();_drag_side=""
	if is_instance_valid(_marker):_marker.hide()

## _release() would change nothing (W2 perf pass: it ran, and rebuilt _previous, every tick
## while the desktop was unavailable).
func _released()->bool:
	if is_instance_valid(current) or not _desktop.is_empty() or _drag_side!="":return false
	if _previous.size()!=2 or _previous.get("left")!=true or _previous.get("right")!=true:return false
	if is_instance_valid(_marker) and _marker.visible:return false
	return not (is_instance_valid(inventory) and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self)

func cancel_desktop_activity()->void:
	if not _xr:_release()

func _unclaim()->void:
	if is_instance_valid(inventory) and inventory.has_meta("desktop_activity_owner") and inventory.get_meta("desktop_activity_owner")==self:
		inventory.remove_meta("desktop_activity_owner")

func _notification(what:int)->void:
	if what==NOTIFICATION_APPLICATION_FOCUS_OUT:_release()

func _exit_tree()->void:
	_release()
	if is_instance_valid(current):current.end(true)
