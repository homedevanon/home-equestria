extends RefCounted
## Interruptible native FK clips. Original entry/exit timing; final pose holds.
const LIBRARY = preload("res://world/characters/hybrid_mare/pony_postures.res")
const FK = preload("res://world/characters/locomotion/limb_solver.gd")
var pony: CharacterBody3D
var requested := "stand"
var kind := "sit"
var progress := 0.0
var rate := 0.0
var refusal := ""
var _wait := 0.0
var _rise_retry := 0.0
var _rising_on_capsule := false
var ready := false
var _last_progress := -1.0
var _last_slope := Basis.IDENTITY
var _last_root := Transform3D.IDENTITY
var _slope := Basis.IDENTITY
var _tracks: Dictionary = {}
var _position_tracks: Dictionary = {}
var _source_bounds: Dictionary = {}
var _sweep_bounds: Dictionary = {}
var _saved_limits: Dictionary = {}
var _handoff := false
var source_time := 0.0
var _last_source_time := -1.0
var review_paused := false
var seated_seconds := 0.0
var lie_after_seconds := 30.0
var automatic_rest := true
## An accepted sit/lie action persists until stand, travel, carrying or lost support.
var intentional_rest := false
var _initial: Array[Transform3D] = []
var _initial_pivot := Transform3D.IDENTITY
var phase := "stand"
var clip := "sit"
var _join_time := 0.0
var _standing_shape: Shape3D
var _standing_position := Vector3.ZERO
var _standing_transform := Transform3D.IDENTITY
var _box := BoxShape3D.new()
var _native_pose: Array[Transform3D] = []
## Clip tiers (docs/CLIP_TIER_2026_09_25.md): the state machine runs as usual, but the pony plays
## the baked posture clips instead of this FK, and has no collision body to fit or rays to cast.
var clip_output := false
## Soft bedding (dev 2026-09-28: "make sure the mares TOUCH the bed not float off of it. slightly
## clip into the bed as to simulate depressing into the foam"). Lying on a bed, the posture box
## rises by soft_sink, so her root settles below the flat physics mattress until the lowest point
## of the lying pose meets the drawn bedding and presses MATTRESS.SINK into it. The clip tiers have
## no body: their root moves instead, at most CLIP_SINK (the solver re-seats anything 3 cm under a
## surface when she turns HERO again). Floors, benches and sofas keep soft_sink at zero.
const MATTRESS := preload("res://world/life/couch/mattress.gd")
const SOFT_MAX := 0.1
const CLIP_SINK := 0.028
var soft_sink := 0.0
var _soft_goal := 0.0
var _soft_at := Vector3.INF
var _soft_top := NAN
var _last_sink := 0.0
var _lying_bottom := 0.0
func bind(actor: CharacterBody3D) -> void:
	pony=actor
	_standing_shape=pony._collision.shape
	_standing_position=pony._collision.position
	_standing_transform=pony._collision.transform
	for clip in ["sit","lie_down","sit_stand","lie_down_stand"]:
		var anim: Animation=LIBRARY.get_animation(clip)
		var tracks: Array[int]=[]
		for b in pony.skeleton.get_bone_count(): tracks.append(anim.find_track(NodePath("Skeleton3D:"+pony.skeleton.get_bone_name(b)),Animation.TYPE_ROTATION_3D))
		if -1 in tracks: return
		_tracks[clip]=tracks
		var positions:Array[int]=[]
		for b in pony.skeleton.get_bone_count():positions.append(anim.find_track(NodePath("Skeleton3D:"+pony.skeleton.get_bone_name(b)),Animation.TYPE_POSITION_3D))
		_position_tracks[clip]=positions
	for clip in ["sit","lie_down"]:
		var anim:Animation=LIBRARY.get_animation(clip)
		var boxes:Array=anim.get_meta("bounds")
		var sources:Array=LIBRARY.get_animation(clip+"_stand").get_meta("bounds")
		var source_box:AABB=sources[0]
		for box in sources:source_box=source_box.merge(box)
		_source_bounds[clip]=source_box
		var sweep:AABB=source_box
		for box in boxes:sweep=sweep.merge(box)
		_sweep_bounds[clip]=sweep
	# The settled lie-down's lowest point above her root (folded legs and belly), unscaled.
	var lying:Array=LIBRARY.get_animation("lie_down").get_meta("bounds")
	if not lying.is_empty():
		var settled_box:AABB=lying[lying.size()-1]
		_lying_bottom=clampf(settled_box.position.y,-.03,.08)
	ready=true
func active() -> bool: return progress>0.0 or requested!="stand"

func rescale(relative: float) -> void:
	_standing_shape = _standing_shape.duplicate()
	if _standing_shape is CapsuleShape3D:
		_standing_shape.height *= relative
		_standing_shape.radius *= relative
	_standing_transform.origin *= relative
	_standing_position *= relative
	if not active() or _rising_on_capsule:
		_restore_standing_collider()
	_last_source_time = -1.0

## Land in the native prone pose, then use the ordinary rise animation. This
## skips the voluntary lie-down windup without stretching or ragdolling bones.
func impact_flop() -> void:
	reset()
	kind = "lie_down"; requested = kind
	activate_limits(kind)
	_start_clip(kind,"hold")
	source_time = LIBRARY.get_animation(kind).length
	progress = 1.0
	apply()
func settled() -> bool: return (progress==1.0 and requested==kind) or (progress==0.0 and requested=="stand")
func request(value: String) -> bool:
	refusal=""
	if not ready: refusal="Posture rig needs rebaking"; return false
	if value not in ["sit","lie_down","stand"]: refusal="Unknown posture"; return false
	if pony.get("sleeping") == true and value != "lie_down":
		refusal = "Asleep until waking"; return false
	if value=="stand" and pony.has_meta("cuddle_session"):
		var cuddle:Node=pony.get_meta("cuddle_session")
		if cuddle.enabled or cuddle.blend>0.0:
			cuddle.end()
	if value=="stand": intentional_rest=false; requested=value; return true
	if pony._held or pony.carry.blend>0.0 or pony.hoof_hold.leg_index>=0: refusal="Cannot lower while held"; return false
	if not pony.grounded(): refusal="No ground support"; return false
	if pony.actual_speed>.05 or pony._blend>.05: refusal="Wait until stopped"; return false
	# dev (2026-09-16): let them sit anywhere. support() only measures the local slope
	# for the rest basis now; uneven footprints, ledges and tight clearance no longer refuse.
	support()
	if not active():
		kind=value
		activate_limits(kind)
		_start_clip(kind,"enter")
	requested=value
	pony.stop()
	return true
func reset(retain_limits := false) -> void:
	_rising_on_capsule = false
	_rise_retry = 0.0
	intentional_rest=false
	seated_seconds=0.0
	_handoff=retain_limits
	if not retain_limits:restore_limits()
	requested="stand"; phase="stand"; progress=0.0; rate=0.0; _last_progress=-1.0;_last_source_time=-1.0
	soft_sink=0.0;_soft_goal=0.0;_soft_at=Vector3.INF;_soft_top=NAN
	if pony!=null and is_instance_valid(pony._collision):
		_restore_standing_collider()

func _restore_standing_collider() -> void:
	pony._collision.shape = _standing_shape
	pony._collision.transform = _standing_transform

func support() -> bool:
	var center: Dictionary=pony._probe(pony.global_position)
	var bed:Node3D=MATTRESS.bed_of(center.get("collider")) if not center.is_empty() else null
	if bed!=null and (bed.has_meta("mattress_top") or bed.get_meta("shared_rest_support",false)):
		# Wide ground probes can strike a headboard or miss the bed edge, pitching
		# a body on a flat mattress. Use the actual tagged support under her centre.
		var local_hit:Vector3=bed.to_local(center.position)
		var distance:float=0.0 if bed.get_meta("shared_rest_support",false) else absf(local_hit.y-float(bed.get_meta("mattress_top")))*bed.global_basis.y.length()
		if distance<=MATTRESS.TRUST:
			var normal:Vector3=(pony.global_basis.inverse()*Vector3(center.normal)).normalized()
			if not normal.is_finite() or normal.angle_to(Vector3.UP)>deg_to_rad(25.0):normal=Vector3.UP
			_slope=Basis(Quaternion(Vector3.UP,normal))
			return true
	# Local slope from whatever the nine probes find; missing or uneven samples fall back
	# to level. Never a refusal any more (dev: sit anywhere).
	# A sample further above or below her centre than a 25 degree slope allows is a ledge (the
	# spa's massage table end, a bench edge), not ground she lies on: counted as missing, so one
	# probe off a table's end no longer tilts her lying box and lifts her (dev 2026-10-29).
	var heights: Array[Vector3]=[]
	var middle:float=(pony.global_transform.affine_inverse()*Vector3(center.position)).y/pony.body_scale if not center.is_empty() else 0.0
	for z in [-.75,0.0,.75]:
		for x in [-.5,0.0,.5]:
			var hit: Dictionary=center if x==0.0 and z==0.0 else pony._probe(pony.global_transform*(Vector3(x,0,z) * pony.body_scale))
			var at:Vector3=(pony.global_transform.affine_inverse()*Vector3(hit.position)) / pony.body_scale if not hit.is_empty() else Vector3(x,0,z)
			if absf(at.y-middle)>tan(deg_to_rad(25.0))*Vector2(x,z).length()+.01:at=Vector3(x,0,z)
			heights.append(at)
	var dz: float=(heights[7].y-heights[1].y)/1.5
	var dx: float=(heights[5].y-heights[3].y)
	var normal:=Vector3(-dx,1,-dz).normalized()
	if not normal.is_finite() or normal.angle_to(Vector3.UP)>deg_to_rad(25.0): normal=Vector3.UP
	_slope=Basis(Quaternion(Vector3.UP,normal))
	return true
func _clearance_query() -> PhysicsShapeQueryParameters3D:
	var query := PhysicsShapeQueryParameters3D.new()
	var floor_layers: Variant = pony.get("floor_mask")
	query.collision_mask = 2 | (int(floor_layers) if floor_layers != null else 1)
	var excluded: Array[RID] = [pony.get_rid()]
	for other: PhysicsBody3D in pony.get_collision_exceptions():
		excluded.append(other.get_rid())
	query.exclude = excluded
	return query

func clearance(value: String) -> bool:
	# A pony on a bench seat was placed there with its room already measured.
	if pony.has_meta("seated"): return true
	var bounds:AABB=_sweep_bounds[value if value!="stand" else kind]
	# Reserve the whole rise/lower sweep; omit its thin contact band at the floor.
	var bottom:=maxf(.055,bounds.position.y)
	var shape:=BoxShape3D.new(); shape.size=Vector3(bounds.size.x+.04,maxf(.1,bounds.end.y-bottom+.03),bounds.size.z+.04)
	var query := _clearance_query()
	query.shape = shape
	query.transform=pony.global_transform*Transform3D(_slope, _slope*(Vector3(bounds.get_center().x,bottom+shape.size.y*.5,bounds.get_center().z) * pony.body_scale))
	# Pressed into a mattress, she rises out of the foam first: measure from the bedding's top.
	query.transform.origin+=Vector3.UP*soft_sink
	shape.size *= pony.body_scale
	if not pony.get_world_3d().direct_space_state.intersect_shape(query,1).is_empty(): refusal="Not enough room to lower and stand up"; return false
	return true

func _can_begin_rise() -> bool:
	if clip_output: return true
	if _rise_retry > 0.0: return false
	if clearance("stand"):
		refusal = ""
		return true
	if requested == "stand" and pony.grounded():
		var query := _clearance_query()
		query.shape = _standing_shape
		query.transform = pony.global_transform * _standing_transform
		if pony.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty():
			_rising_on_capsule = true
			_restore_standing_collider()
			refusal = ""
			return true
	_rise_retry = .2
	return false

func _start_clip(name: String, state: String) -> void:
	clip=name;phase=state;source_time=0.0;_join_time=0.0
	_initial=pony.corrected_pose.duplicate() if not pony.corrected_pose.is_empty() else pony.profile.rest.duplicate()
	_initial_pivot=pony.pivot.transform
	_last_source_time=-1.0
	progress=maxf(progress,.000001)

func update(delta: float) -> void:
	_rise_retry = maxf(0.0, _rise_retry - delta)
	_wait-=delta
	if _wait<=0.0:
		_wait=.2
		if not clip_output and not support(): requested="stand"
		_soft_goal=_measure_soft() if kind=="lie_down" and requested=="lie_down" else 0.0
	_ease_soft(delta)
	if pony.get("sleeping") == true and kind == "lie_down":
		requested = "lie_down"
		pony.stop()
	elif (not pony._interaction.is_empty() and pony._interaction!="PETTING") or pony._desired.length()>.05: requested="stand"
	if requested=="stand" and pony.has_meta("cuddle_session"):
		var cuddle:Node=pony.get_meta("cuddle_session")
		if cuddle.enabled:cuddle.end()
		if cuddle.blend>0.0:
			apply();return
	if review_paused:
		apply();return
	if automatic_rest and not intentional_rest and phase=="hold" and kind=="sit" and requested=="sit":
		seated_seconds+=delta
		if seated_seconds>=lie_after_seconds and _wait==.2:
			if request("lie_down"):
				var nav:=pony.get_node_or_null("Navigator")
				if nav!=null and "_idle_time" in nav:nav._idle_time=maxf(nav._idle_time,15.0)
	elif requested=="stand":seated_seconds=0.0
	if phase=="recover":
		_join_time+=minf(delta,.25)
		_last_source_time=-1.0
		apply()
		if _join_time>=.2:
			var next:=requested
			reset();pony._initialized=false;pony._spawn_settle=.2
			if next!="stand":
				kind=next;requested=next;activate_limits(kind);_start_clip(kind,"enter")
		return
	if phase in ["hold", "enter"] and requested != kind:
		if not _can_begin_rise(): return
		if phase == "hold": _start_clip(kind + "_stand", "exit")
		else: phase = "reverse"
	elif phase == "reverse" and requested == kind and not _rising_on_capsule:
		phase = "enter"
	var duration:float=LIBRARY.get_animation(clip).length
	var step:=minf(delta,.25)
	_join_time+=step
	if phase=="enter" or phase=="exit":source_time=minf(duration,source_time+step)
	elif phase=="reverse":source_time=maxf(0.,source_time-step)
	progress=1.0-source_time/duration if phase=="exit" else source_time/duration
	if phase=="hold":progress=1.0
	apply()
	if phase=="enter" and source_time>=duration:
		phase="hold";progress=1.0
	elif (phase=="exit" and source_time>=duration) or (phase=="reverse" and source_time<=0.0):
		phase="recover";progress=.000001;_join_time=0.
		_initial=pony.corrected_pose.duplicate();_initial_pivot=pony.pivot.transform

func apply() -> void:
	if clip_output: return
	if source_time==_last_source_time and _join_time>=.18 and _slope.is_equal_approx(_last_slope) and pony.global_transform.is_equal_approx(_last_root) and soft_sink==_last_sink:return
	_last_source_time=source_time;_last_progress=progress;_last_slope=_slope;_last_root=pony.global_transform;_last_sink=soft_sink
	var anim:Animation=LIBRARY.get_animation(clip)
	var pose:Array[Transform3D]=pony.profile.rest.duplicate()
	for b in pose.size():
		var t:int=_tracks[clip][b];var p:int=_position_tracks[clip][b]
		pose[b].basis=Basis(anim.rotation_track_interpolate(t,source_time)).scaled_local(pose[b].basis.get_scale())
		pose[b].origin=pony.profile.native_position(b,anim.position_track_interpolate(p,source_time))
	var pivot:=Transform3D(_slope,Vector3.ZERO)
	# Brief inertial handoff only at clip boundaries. The native motion/timing
	# and source joint translations remain intact after this join.
	var amount:=smoothstep(0.,.18,_join_time)
	if phase=="recover":
		pose=pony.profile.standing.duplicate()
		amount=smoothstep(0.,.2,_join_time)
	if not _initial.is_empty() and amount<1.0:
		for b in pose.size():pose[b]=_initial[b].interpolate_with(pose[b],amount)
		pivot=_initial_pivot.interpolate_with(pivot,amount)
	pony.source_pose=pose
	_native_pose=pose.duplicate()
	pony.corrected_pose=pose.duplicate()
	pony.pivot.transform=pivot
	if pony.has_method("_apply_body_scale"):pony._apply_body_scale()
	pony.modifier.prepared=pose
	var globals:=FK.forward_kinematics(pony.profile.parents,pose,pony.global_transform*pivot*pony._model_frame)
	for i in 4:
		var leg:Dictionary=pony.profile.legs[i];var foot:Dictionary=pony.feet[i]
		foot.dynamic_sole=leg.sole;foot.target=globals[leg.leaf]*Vector3(leg.sole)
		foot.valid=false;foot.planted=false;foot.weight=0.;foot.correction_angle=0.
	# Once a tight rise starts, keep its fitted collider through recovery. A new
	# sit can begin from stand after recovery, when reset restores normal posture rules.
	if _rising_on_capsule: return
	# Keep the complete native transition sweep reserved for safe interruption.
	var box:AABB=_sweep_bounds[kind]
	_box.size=Vector3(maxf(.38,box.size.x),maxf(.3,box.end.y),maxf(.38,box.size.z)) * pony.body_scale
	pony._collision.shape=_box
	# soft_sink lifts the box off her root, so the root settles into the bedding below it.
	pony._collision.transform=Transform3D(_slope,_slope*Vector3(box.get_center().x * pony.body_scale,_box.size.y*.5,box.get_center().z * pony.body_scale)+Vector3.UP*soft_sink)

## How far below the physics mattress her root belongs: the flat collider top minus the drawn
## bedding under her body, plus the lying pose's lowest point and the foam press. 0 off beds.
func _measure_soft() -> float:
	var root:=pony.global_position
	if _soft_at.is_finite() and Vector2(root.x-_soft_at.x,root.z-_soft_at.z).length()<.03:return _soft_goal
	_soft_at=root
	var mask:int=int(pony.get("floor_mask")) if pony.get("floor_mask")!=null else 1
	var ray:=PhysicsRayQueryParameters3D.create(root+Vector3.UP*.5,root+Vector3.DOWN*.4,mask,[pony.get_rid()])
	var hit:Dictionary=pony.get_world_3d().direct_space_state.intersect_ray(ray)
	var bed:Node3D=MATTRESS.bed_of(hit.get("collider")) if not hit.is_empty() else null
	if bed==null or bed.get_meta("shared_rest_support",false):
		# A partner supports her weight; this is not foam to sink through.
		_soft_top=NAN
		return 0.0
	_soft_top=float(hit.position.y)
	var scale:float=float(pony.body_scale)
	var along:Vector3=pony.global_basis.z.normalized()*.25*scale
	var across:Vector3=pony.global_basis.x.normalized()*.1*scale
	var points:Array[Vector3]=[root,root+along,root-along,root+across,root-across]
	var surface:=MATTRESS.visible_top(bed,points,_soft_top)
	return clampf(_soft_top-surface+_lying_bottom*scale+MATTRESS.SINK,0.0,SOFT_MAX)

## Sinks in while she lies down and rises back out as she gets up (progress), a few cm per second.
func _ease_soft(delta: float) -> void:
	var goal:=_soft_goal*progress if kind=="lie_down" else 0.0
	var before:=soft_sink
	soft_sink=move_toward(soft_sink,goal,minf(delta,.25)*.12)
	# No body on the clip tiers: the root itself rests in the bedding.
	if clip_output and is_finite(_soft_top) and (before>0.0 or soft_sink>0.0):
		var y:=_soft_top-minf(soft_sink,CLIP_SINK)
		if absf(pony.global_position.y-y)>.001:pony.global_position.y=y

func activate_limits(clip:String) -> void:
	if _saved_limits.is_empty():_saved_limits=pony.joint_limits.joints.duplicate(true)
	pony.joint_limits.joints=_saved_limits.duplicate(true)
	var bounds:Dictionary=LIBRARY.get_animation(clip).get_meta("joint_envelopes")
	for b in bounds:
		# Test mares carry a reduced limit table; a bone it lacks keeps no envelope.
		if not pony.joint_limits.joints.has(b):continue
		var j:Dictionary=pony.joint_limits.joints[b]
		j.lower=bounds[b].x;j.upper=bounds[b].y;j.swing=bounds[b].z

## Sleep styles on top of the settled lie-down, blended into hand-authored poses
## (tools/sleep_poses/author.gd): "head_down" curls up with the head on the ground by the
## forehooves; "side" rolls over (halfway pose first) onto the right side, legs out.
## Lie styles use the same blend for an awake pony: meta "lie_style" = "stretch" lies flat like a
## lifesize plush, forelegs forward and hind legs straight back (the spa's massage table).
const SLEEP_POSES:=preload("res://world/characters/hybrid_mare/sleep_poses.res")
var _sleep_blend:=0.0
var _sleep_style:=""
var _sleep_targets:={}   # pose name -> Array[Transform3D] for every bone
## One key per style, blended in while the lie-down itself plays, so lying down and settling
## into the sleep pose are one short motion instead of two.
const SLEEP_SEQUENCES:={"head_down":[["curl",1.0]],"side":[["side",1.0]],"stretch":[["stretch",1.0]]}
const SLEEP_SECONDS:={"head_down":1.3,"side":1.3,"stretch":1.3}
func _sleep_target(name:String) -> Array:
	if _sleep_targets.has(name):return _sleep_targets[name]
	var sk:Skeleton3D=pony.skeleton
	var poses:Dictionary=SLEEP_POSES.get_meta("poses")
	var out:Array=[]
	for b in sk.get_bone_count():out.append(sk.get_bone_rest(b))
	for bone_name in poses[name]:
		var b:=sk.find_bone(bone_name)
		if b<0:continue
		var v:Array=poses[name][bone_name]
		out[b]=Transform3D(Basis(v[0] as Quaternion).scaled(sk.get_bone_rest(b).basis.get_scale()),v[1])
	_sleep_targets[name]=out
	return out
## The sleep style's blend in and out (state only; apply_attention() and the clip tiers read it).
## Returns the style being settled into, "" while waking or awake.
func advance_sleep(step: float) -> String:
	var style:=str(pony.get("sleep_style")) if pony.get("sleeping")==true and kind=="lie_down" and requested=="lie_down" else ""
	if style.is_empty() and kind=="lie_down" and requested=="lie_down" and pony.get_meta("couch_cuddle",false): style="head_down"
	if style.is_empty() and kind=="lie_down" and requested=="lie_down" and pony.has_meta("lie_style"): style=str(pony.get_meta("lie_style"))
	# Switching style while asleep: unwind the old pose first, then settle into the new one.
	if style!="" and _sleep_style!="" and style!=_sleep_style and _sleep_blend>0.0:style=""
	if style!="":_sleep_style=style
	var seconds:float=SLEEP_SECONDS.get(style if style!="" else _sleep_style,1.3)
	# Settling in plays the staged keys forward; waking plays them back a little faster.
	_sleep_blend=move_toward(_sleep_blend,1.0 if style!="" else 0.0,step/(seconds if style!="" else seconds*.6))
	if _sleep_blend<=0.0:_sleep_style=""
	return style
## Seconds the sleep blend takes toward `style` ("" = waking).
func sleep_seconds(style: String) -> float:
	var seconds:float=SLEEP_SECONDS.get(style if style!="" else _sleep_style,1.3)
	return seconds if style!="" else seconds*.6
## The pose SLEEP_SEQUENCES names for a style ("head_down" curls up, "side" rolls over).
func sleep_pose_name(style: String) -> String:
	var sequence:Array=SLEEP_SEQUENCES.get(style,[])
	return str(sequence[-1][0]) if not sequence.is_empty() else ""
func apply_attention() -> void:
	if review_paused or _native_pose.is_empty(): return
	var live := _native_pose.duplicate()
	advance_sleep(pony.get_physics_process_delta_time())
	var cuddling:bool=pony.get_meta("cuddle_active",false) and not pony.sleeping
	var supported_head:bool=pony.get_meta("shared_nap_head_supported",false)
	if not cuddling and not supported_head:pony.secondary.apply_rest_gaze(live)
	if _sleep_style!="" and _sleep_blend>0.0:
		var sequence:Array=SLEEP_SEQUENCES[_sleep_style]
		for i in live.size():
			var t:=_sleep_blend
			var current:Transform3D=live[i];var previous:=0.0
			for key:Array in sequence:
				var part:=clampf((t-previous)/(float(key[1])-previous),0.0,1.0)
				if part<=0.0:break
				current=current.interpolate_with(_sleep_target(key[0])[i],smoothstep(0.0,1.0,part))
				previous=float(key[1])
			live[i]=current
	# The couch curl keeps its native body pose; an awake companion can still look around.
	if cuddling and not supported_head:pony.secondary.apply_rest_gaze(live)
	pony.corrected_pose=live
	pony.modifier.prepared=live
func restore_limits() -> void:
	if not _saved_limits.is_empty():pony.joint_limits.joints=_saved_limits;_saved_limits={}
	_handoff=false
func release_limits_when_safe() -> void:
	if _handoff and ((pony.carry.active and pony.carry.blend>=1.0) or (not pony.carry.active and pony.carry.blend<=0.0)):restore_limits()
