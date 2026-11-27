extends Node
## One supported whole-body posing session. No updates or solver work while walking.
const SOLVER:=preload("res://world/relationships/cuddle/pose_solver.gd")
var mare:CharacterBody3D
var partner:Node3D
var support:Node3D
var enabled:=false
var blend:=0.0
var solvers:Array[Node]=[]
var grips:Dictionary={}
var _origin:=Vector3.ZERO
var _previous_owner:=""
var _previous_wander:=false
var _token:=""
var _cooldown:=0.0
var _capsule:SphereShape3D
var _query:PhysicsShapeQueryParameters3D

func _ready()->void:
	mare.set_meta("cuddle_session",self)
	# A body without the pony rig the pose solvers drive (Spike) has no posed cuddle session.
	if mare.get("cuddle_supported")==false:
		set_physics_process(false);return
	var body:=SOLVER.new();body.name="CuddleBodyPose";body.session=self
	mare.skeleton.add_child(body)
	# Body posing precedes proportions; head/hair links read the final skeleton pose.
	if mare.get("_clip_head")!=null:mare.skeleton.move_child(body,mare._clip_head.get_index()+1)
	solvers.append(body)
	if is_instance_valid(mare.hair_skeleton):
		var tail_solver:=SOLVER.new();tail_solver.name="CuddleTailPose";tail_solver.session=self;tail_solver.tail=true
		mare.hair_skeleton.add_child(tail_solver);solvers.append(tail_solver)
	_capsule=SphereShape3D.new();_query=PhysicsShapeQueryParameters3D.new();_query.shape=_capsule
	_query.collision_mask=1;_query.exclude=[mare.get_rid()]
	process_physics_priority=10
	set_physics_process(false)

func willing()->bool:
	var runtime:Node=mare.get_meta("relationship_runtime") if mare.has_meta("relationship_runtime") else null
	return runtime==null or runtime.bonds.welcomes(str(mare.get_meta("relationship_id","")),"hug")

func can_begin(body:Node3D)->bool:
	if enabled or blend>0.0 or Time.get_ticks_msec()<_cooldown:return false
	if mare.get("cuddle_supported")==false:return false
	if not is_instance_valid(body) or (body.get("controls_locked")==true and not _sleeping_rest(body)) or body.get("flying")==true:return false
	if mare.is_held() or mare.actual_speed>.05 or not willing():return false
	if mare.get_meta("affection_active",false):return false
	if mare.get("flight")!=null and mare.flight.active():return false
	if mare.hoof_hold.active():return false
	var state:Dictionary=mare.posture_status()
	return state.requested in ["sit","lie_down"] and state.settled and _gap(body)<2.5

## Distance to the player where they really are. A VR rig origin is the room-scale centre, which
## a bed or couch rest moves wherever it must put the tracked head; the head is the player.
func _gap(body:Node3D)->float:
	var camera:Camera3D=preload("res://world/player_view.gd").camera(body)
	if camera is XRCamera3D and body.is_ancestor_of(camera):
		return Vector2(camera.global_position.x-mare.global_position.x,camera.global_position.z-mare.global_position.z).length()
	return body.global_position.distance_to(mare.global_position)

func begin(body:Node3D, surface:Node3D=null)->bool:
	if not can_begin(body):return false
	partner=body;support=surface;enabled=true;blend=0.0;_origin=mare.global_position
	var nav:=mare.get_node_or_null("Navigator")
	if nav!=null:
		_previous_owner=nav.command_owner;_previous_wander=nav.wander_enabled
		_token=_previous_owner if mare.has_meta("seating") or _previous_owner.begins_with("sleep:") else "cuddle:"+str(get_instance_id())
		nav.stay();nav.command_owner=_token;nav.wander_enabled=false
	mare.set_meta("cuddle_active",true)
	mare.set_sim_tier(mare.SimTier.HERO)
	for solver:Node in solvers:solver.clear();solver.active=true
	set_physics_process(true)
	return true

func end(immediate:=false)->void:
	if not enabled and blend<=0.0:return
	enabled=false;release_all();_cooldown=Time.get_ticks_msec()+1500
	mare.remove_meta("cuddle_active")
	if immediate:blend=0.0;_finish()

func _finish()->void:
	for solver:Node in solvers:
		if is_instance_valid(solver):solver.clear()
	var nav:=mare.get_node_or_null("Navigator") if is_instance_valid(mare) else null
	if nav!=null and nav.command_owner==_token:
		nav.command_owner=_previous_owner;nav.wander_enabled=_previous_wander
	partner=null;support=null;set_physics_process(false)

func _physics_process(delta:float)->void:
	if not is_instance_valid(mare):end(true);return
	if enabled:
		var nav:=mare.get_node_or_null("Navigator")
		# The open chat box locks movement too (world/ui/chat_box.gd "chat_typing"); typing to her is
		# not a reason to end the cuddle (player board #44).
		var locked:bool=partner.get("controls_locked")==true and not _sleeping_rest(partner) and not partner.get_meta("chat_typing",false) if is_instance_valid(partner) else false
		var invalid:bool=not is_instance_valid(partner) or locked or partner.get("flying")==true
		invalid=invalid or not willing() or mare.is_held() or mare.global_position.distance_to(_origin)>.18 or mare.actual_speed>.12
		invalid=invalid or mare.posture_status().requested not in ["sit","lie_down"] or (nav!=null and nav.command_owner!=_token)
		if not invalid:invalid=_gap(partner)>2.8
		if not invalid and support!=null:invalid=not is_instance_valid(support) or not partner.get_meta("couch_sleeping",false)
		if invalid:end()
	blend=move_toward(blend,1.0 if enabled else 0.0,minf(delta,.05)/.45)
	if not enabled and blend<=0.0:_finish()

func pick(point:Vector3,reach:=.08)->Dictionary:
	var best:Dictionary={};var gap:=reach
	for solver:Node in solvers:
		var hit:Dictionary=solver.choose(point,gap)
		if not hit.is_empty():best=hit;gap=hit.distance
	return best

func pick_ray(from:Vector3,direction:Vector3,length:=2.5)->Dictionary:
	var best:Dictionary={};var nearest:=length
	for solver:Node in solvers:
		for id:String in solver.regions:
			var point:Vector3=solver.point(id)
			var along:float=(point-from).dot(direction)
			if along<=0.0 or along>nearest:continue
			var radius:float=solver.regions[id].radius*mare.body_scale
			if point.distance_to(from+direction*along)>radius:continue
			if not visible(from,point):continue
			best={"solver":solver,"id":id,"point":point,"distance":along};nearest=along
	return best

func visible(from:Vector3,to:Vector3)->bool:
	var excludes:Array[RID]=[mare.get_rid()]
	if partner is CollisionObject3D:excludes.append(partner.get_rid())
	return mare.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from,to,1,excludes)).is_empty()

func take(side:String,hit:Dictionary,hand:Transform3D)->bool:
	if not enabled or grips.has(side) or hit.is_empty() or not hand.is_finite():return false
	if not visible(hand.origin,hit.point):return false
	for held:Dictionary in grips.values():
		if held.solver==hit.solver and held.id==hit.id:return false
	# Explicit hands can replace passive shared-rest guidance. Preserve every real
	# grip, including another point on this limb, and restore passive state if rejected.
	var passive:Dictionary={}
	for id:String in hit.solver.targets.keys():
		if hit.solver._group(id)!=hit.solver._group(hit.id):continue
		var target:Dictionary=hit.solver.targets[id]
		if not target.get("shared_nap_target",false):continue
		var player_owned:=false
		for held:Dictionary in grips.values():
			if held.solver==hit.solver and held.id==id:player_owned=true
		if player_owned:continue
		passive[id]=target.duplicate(true)
	for id:String in passive:hit.solver.targets.erase(id)
	if not hit.solver.take(hit.id,hand):
		for id:String in passive:hit.solver.targets[id]=passive[id]
		return false
	grips[side]=hit.duplicate();return true

func guide(side:String,hand:Transform3D)->void:
	if not grips.has(side):return
	var hit:Dictionary=grips[side]
	hit.solver.guide(hit.id,hand)
	if not hit.solver.targets.get(hit.id,{}).get("held",false):release(side)

func release(side:String)->void:
	if not grips.has(side):return
	var hit:Dictionary=grips[side]
	if is_instance_valid(hit.solver):hit.solver.release(hit.id)
	grips.erase(side)

func release_all()->void:
	for side:String in grips.keys():release(side)

func grip_point(side:String)->Vector3:
	return grips[side].solver.point(grips[side].id) if grips.has(side) else Vector3.INF

func _partner_frame()->Transform3D:
	if not is_instance_valid(partner):return Transform3D(Basis.IDENTITY,Vector3.INF)
	var avatar:=partner.find_child("AnonBody",true,false)
	if avatar==null:avatar=partner.find_child("CouchAnonBody",true,false)
	if avatar!=null and avatar.get("_hip_target")!=null:
		return avatar._hip_target.global_transform.orthonormalized()
	return partner.global_transform.orthonormalized()

func partner_point(local:Vector3)->Vector3:
	var frame:=_partner_frame()
	return frame*local if frame.origin.is_finite() else Vector3.INF

func partner_support(point:Vector3,radius:float)->Dictionary:
	var frame:=_partner_frame()
	if not frame.origin.is_finite():return {}
	var a:=frame.origin;var b:=a+frame.basis.y*.48
	var segment:=b-a
	var nearest:=a+segment*clampf((point-a).dot(segment)/segment.length_squared(),0.0,1.0)
	if absf(point.distance_to(nearest)-.16-radius)<.06:
		return {"local":frame.affine_inverse()*point}
	return {}

func project_contact(previous:Vector3,goal:Vector3,radius:float)->Vector3:
	if not previous.is_finite() or not goal.is_finite():return previous
	var desired:=previous+(goal-previous).limit_length(.025)
	_capsule.radius=radius*mare.body_scale
	_query.transform=Transform3D(Basis.IDENTITY,previous);_query.motion=desired-previous
	var space:=mare.get_world_3d().direct_space_state
	var fraction:=space.cast_motion(_query)
	if fraction.size()>0:desired=previous+(desired-previous)*fraction[0]
	# Floor projection covers targets already touching a cushion at grab time. The ray grows with her
	# body as the contact radius does (player board #56: from about x1.35 a torso or head contact was
	# wider than the 18 cm ray, so it pressed into the mattress); unchanged at canon size and below.
	var reach:=maxf(1.0,mare.body_scale)
	var ray:=PhysicsRayQueryParameters3D.create(desired+Vector3.UP*.10*reach,desired-Vector3.UP*.18*reach,1,[mare.get_rid()])
	var hit:=space.intersect_ray(ray)
	if not hit.is_empty() and hit.normal.y>.65:desired.y=maxf(desired.y,float(hit.position.y)+_capsule.radius)
	return desired

func _exit_tree()->void:
	if is_instance_valid(mare):mare.remove_meta("cuddle_active");mare.remove_meta("cuddle_session")
	for solver:Node in solvers:
		if is_instance_valid(solver):solver.queue_free()

## Only the real sleep transition may retain a supported rest through its input lock.
func _sleeping_rest(body: Node3D) -> bool:
	return body.get_meta("shared_rest_sleeping", false) and body.get_meta("couch_sleeping", false) and is_instance_valid(body.get("seat"))
