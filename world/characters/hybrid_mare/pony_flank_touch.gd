extends Node3D
## Swept palm hitboxes in the native body frame, independent of gaze/render LOD.
const CROWD_PROFILE := preload("res://tools/crowd_cpu_profile.gd")  # timed only under the crowd lab's --profile-cpu
const DOCK := preload("res://world/characters/hybrid_mare/hybrid_dock.gd")
const HITCH := preload("res://world/debug/hitch_monitor.gd")
const FADE_SECONDS := 18.0
const SURFACE := preload("res://world/characters/hybrid_mare/flank_surface.gd")
var surface:RefCounted
var _surface_tick:=-1
var contact_time:Dictionary={}
var motion_window:Dictionary={}
var latched_contact:Dictionary={}
var last_hit:Dictionary={}
const CONTACT_WINDOW := .10
const MOTION_WINDOW := .05
## Opt-in lab telemetry; disabled in ordinary play, no trace allocation when off.
signal hand_diagnostic(side:String,reading:Dictionary)
var diagnostics_enabled:=false
func _trace(side:String,reason:String,result:int=-1,speed:float=-1.0,facing:float=-2.0)->int:
	if diagnostics_enabled:
		hand_diagnostic.emit(side,{"reason":reason,"target":result,"speed":speed,"facing":facing,"count":count,"armed":bool(armed.get(side,false)),"latched":bool(latched.get(side,false)),"time_us":Time.get_ticks_usec()})
	return result

var mare:Node3D
var frame:=Transform3D.IDENTITY
var previous:Dictionary={}
var motion_previous:Dictionary={}
var armed:Dictionary={}
const MIN_STRIKE_SPEED := 0.75
const WITHDRAWAL := 0.06
var latched:Dictionary={}
var marks:Array[Decal]=[]
var mark_attachments:Array=[]
var ages:Array[float]=[]
var centers:Array[Vector3]=[]
var normals:Array[Vector3]=[]   # outward surface normal per target, body rest space
var radii:=Vector3(.23,.20,.10) # across, up, outward: includes palm collision clearance
var count:=0
var sound:AudioStreamPlayer3D
var _hips:=-1
var _bind:=Transform3D.IDENTITY
static var texture:ImageTexture
## [kind, meshes..., targets...] -> {center, normal}. Every pony of a body shape shares its body
## and mark meshes, so these fits (a mesh readback and passes over ~8k vertices) run once.
static var _fit_cache:={}
## True from an impact until every redness decal has faded out.
var _fading:=false
## Where _pose_updated would have put this node (parent space) while it stays unmoved.
var _local:=Transform3D.IDENTITY
## Clip tiers (beyond hand reach) with no redness showing: no physics tick, and the per-pose
## frame is left stale (`frame`/`_local` are refreshed by an offer, an impact or the wake).
## The mare's tier change (hybrid_mare.set_sim_tier) or an impact wakes it.
var _parked:=false
## Slap wobble (dev 2026-10-20): flank_jiggle.gdshaderinc on the coat and its outline hull.
## JIGGLE_MAX is the first push in metres for the hardest slap; the wobble settles within
## JIGGLE_SECONDS. _process runs only while a wobble plays.
## Close ponies draw merged meshes (hybrid_near_mesh.gd, near_pony*.gdshader), not the rig, so
## every body-skeleton mesh wearing one of JIGGLE_SHADERS is driven. The cutie-mark patches wear
## a StandardMaterial3D; during a wobble their surface borrows MARK_SHADER (same look) and gets
## it back afterwards. Uniforms return to their defaults when a wobble ends: the near mesh only
## merges materials whose extra uniforms are at default.
const JIGGLE_MAX := 0.04
const JIGGLE_SECONDS := 1.4
const JIGGLE_UNIFORMS := ["jiggle_amount","jiggle_time","jiggle_center","jiggle_normal","jiggle_entry"]
const JIGGLE_SHADERS := [preload("res://addons/cel-shader/cel-shader-base.gdshader"),
	preload("res://addons/cel-shader/cel-outline-lit.gdshader"),preload("res://addons/cel-shader/outline-tinted.gdshader"),
	preload("res://world/characters/hybrid_mare/near_pony.gdshader"),preload("res://world/characters/hybrid_mare/near_pony_occlusion.gdshader"),
	preload("res://world/characters/hybrid_mare/near_pony_outline.gdshader")]
const MARK_SHADER := preload("res://world/characters/hybrid_mare/cutie_mark_jiggle.gdshader")
const NEAR_MESH_META := preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd").META
const NEAR_MESH_ENTRIES := preload("res://world/characters/hybrid_mare/hybrid_near_mesh.gd").ENTRIES
var _body:MeshInstance3D
var _jiggle_index:=-1
var _jiggle_age:=0.0
var _jiggle_amount:=0.0
## [material, mesh instance] pairs: the centre goes to each material in its own mesh's space.
var _jiggle_targets:Array=[]
## [mesh instance, surface, override before, borrowed twin] for each cutie-mark surface.
var _borrowed_marks:Array=[]

func wake_tick() -> void:
	if not _parked:return
	_parked=false
	set_physics_process(true)
	if is_instance_valid(mare) and is_instance_valid(mare.skeleton) and not mare.skeleton.skeleton_updated.is_connected(_pose_updated):
		mare.skeleton.skeleton_updated.connect(_pose_updated)
	_pose_now()

func _park() -> void:
	_parked=true
	set_physics_process(false)
	if is_instance_valid(mare.skeleton) and mare.skeleton.skeleton_updated.is_connected(_pose_updated):
		mare.skeleton.skeleton_updated.disconnect(_pose_updated)

## An explicit desktop slap chooses the same skinned patch and feedback as a VR impact.
## Mouse intent is a command, not invented controller velocity. Re-query at animation contact.
func desktop_offer(origin:Vector3,end:Vector3) -> Dictionary:
	if surface==null or not origin.is_finite() or not end.is_finite() or mare.is_held():return {}
	_pose_now()
	if not frame.is_finite():return {}
	surface.update_pose(mare.skeleton,frame)
	var hit:Dictionary=surface._cast(frame.affine_inverse()*origin,frame.affine_inverse()*end)
	if hit.is_empty():return {}
	var point:Vector3=frame*Vector3(hit.position)
	var normal:Vector3=(frame.basis.inverse().transposed()*Vector3(hit.normal)).normalized()
	if normal.dot(origin-point)<=0:return {}
	return {"target":mare,"point":point,"normal":normal,"surface_hit":hit,"visible_pick":true}

func desktop_impact(offer:Dictionary) -> bool:
	if surface==null or offer.is_empty() or not offer.has("surface_hit") or mare.is_held():return false
	last_hit=offer.surface_hit
	var normal:Vector3=last_hit.normal
	var index:int=2 if normal.z>absf(normal.x) else (0 if normal.x<0 else 1)
	impact(index,last_hit.position)
	return true

func setup(pony:Node3D) -> void:
	mare=pony
	_hips=mare.skeleton.find_bone("pony_hips")
	var body:MeshInstance3D=mare._model.find_child("MareBody",true,false)
	_body=body
	set_process(false)
	_bind=DOCK.TAIL_MOUNT.bind_for(body,"pony_hips")
	var bounds:AABB=body.mesh.get_aabb()
	# Broad contact targets cover the flank. Visible redness is fitted separately
	# to the rounded rear cheeks, behind the cutie marks (dev's latest placement).
	for name in ["Cutie mark_L","Cutie mark_R"]:
		var patch:MeshInstance3D=mare._model.find_child(name,true,false)
		if patch==null:continue
		var key:=["surface",patch.mesh]
		var fit:Dictionary=_fit_cache.get(key,{})
		if fit.is_empty():fit=_surface_fit(patch.mesh);_fit_cache[key]=fit
		centers.append(fit.center);normals.append(fit.normal)
		patch.layers|=1<<19   # the mark must redden with the coat around it
	if centers.size()!=2:
		centers=[Vector3(-bounds.size.x*.34,bounds.end.y*.74,bounds.end.z*.56),Vector3(bounds.size.x*.34,bounds.end.y*.74,bounds.end.z*.56)]
		normals=[Vector3.LEFT,Vector3.RIGHT]
	var rump_key:=["rump",body.mesh,centers[0],centers[1]]
	var rump:Dictionary=_fit_cache.get(rump_key,{})
	if rump.is_empty():rump=_rump_fit(body.mesh,centers);_fit_cache[rump_key]=rump
	centers.append(rump.center);normals.append(rump.normal)
	surface=SURFACE.new(body,centers)
	if texture==null:
		var image:=Image.create(64,64,false,Image.FORMAT_RGBA8)
		for y in 64:
			for x in 64:
				var distance:=Vector2((x-31.5)/31.5,(y-31.5)/31.5).length()
				image.set_pixel(x,y,Color(1,1,1,pow(1-smoothstep(.1,1,distance),1.5)))
		texture=ImageTexture.create_from_image(image)
	for i in centers.size():
		var decal:=Decal.new();decal.texture_albedo=texture
		decal.modulate=Color("de5263");decal.size=Vector3(.16,.10,.18)
		decal.upper_fade=.2;decal.lower_fade=.25;decal.albedo_mix=0
		# Fade on coat that faces away from the projector (the rump curving off
		# behind a flank mark) instead of smearing the blob along it.
		decal.normal_fade=.6
		decal.cull_mask=1<<19;decal.visible=false;add_child(decal)
		marks.append(decal);ages.append(FADE_SECONDS)
		mark_attachments.append([])
	# Isolate the projection to this body's coat, not nearby scenery/hair.
	body.layers|=1<<19
	sound=AudioStreamPlayer3D.new()
	sound.bus = "SFX" if AudioServer.get_bus_index("SFX") >= 0 else "Master"
	# dev (2026-09-14): the synthetic smack sounded bad; this is his downloaded slap,
	# trimmed so the transient starts at sample 0 (world/audio/pony/flank_slap.source.json).
	sound.stream=load("res://world/audio/pony/flank_slap.wav")
	sound.volume_db=-10;sound.unit_size=1.5;sound.max_distance=12;add_child(sound)
	mare.skeleton.skeleton_updated.connect(_pose_updated)
	_pose_updated()

## Mean vertex and mean normal of a whole mesh (the native mark patches are
## small skinned strips lying on the coat, so this is the mark's surface).
static func _surface_fit(mesh:Mesh) -> Dictionary:
	var pos:=Vector3.ZERO;var nrm:=Vector3.ZERO;var count:=0
	for surface in mesh.get_surface_count():
		var arrays:=mesh.surface_get_arrays(surface)
		var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var normals_in:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			pos+=vertices[i];nrm+=normals_in[i];count+=1
	if count==0:return {"center":Vector3.ZERO,"normal":Vector3.RIGHT}
	return {"center":pos/count,"normal":nrm.normalized()}


## Rump target: coat vertices between the two marks, at mark height, facing
## backwards (+Z is the tail end of the native rest pose). Falls back to the old
## nominal point 10 cm behind the marks when the mesh gives nothing.
static func _rump_fit(mesh:Mesh,marks:Array[Vector3]) -> Dictionary:
	var mid:Vector3=(marks[0]+marks[1])*.5
	var pos:=Vector3.ZERO;var nrm:=Vector3.ZERO;var count:=0
	for surface in mesh.get_surface_count():
		var arrays:=mesh.surface_get_arrays(surface)
		var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var normals_in:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
		for i in vertices.size():
			var v:Vector3=vertices[i]
			if absf(v.x-mid.x)>.07 or absf(v.y-mid.y)>.09 or v.z<=mid.z or normals_in[i].z<.6:continue
			pos+=v;nrm+=normals_in[i];count+=1
	if count<12:return {"center":Vector3(mid.x,mid.y,maxf(marks[0].z,marks[1].z)+.10),"normal":Vector3.BACK}
	return {"center":pos/count,"normal":nrm.normalized()}

func _pose_updated() -> void:
	if _parked and not _fading and not sound.playing:return  # nothing shown; readers refresh it
	_pose_now()

func _pose_now() -> void:
	# Skeleton updates can arrive while a saved-game reload detaches the old scene.
	# World transforms are valid only while both the target and its skeleton are in-tree.
	if not is_inside_tree() or not is_instance_valid(mare) or not mare.is_inside_tree(): return
	if not is_instance_valid(mare.skeleton) or not mare.skeleton.is_inside_tree(): return
	_surface_tick=-1
	frame=mare.skeleton.global_transform*mare.skeleton.get_bone_global_pose(_hips)*_bind
	# This node only carries the redness decals and the slap sound, and moving it re-notifies them:
	# it follows only while one shows or plays. impact() puts it where it would have been.
	if _fading or sound.playing:global_transform=frame
	else:_local=mare.global_transform.affine_inverse()*frame
	if _fading:
		for i in marks.size():
			if marks[i].visible and not mark_attachments[i].is_empty():
				marks[i].transform=surface.attached_pose(mark_attachments[i],mare.skeleton,frame)

func advance_hand(side:String,world:Vector3,delta:float,active:bool=true,
		palm:Vector3=Vector3.ZERO,reference:Transform3D=Transform3D.IDENTITY,tracked_world:Variant=null) -> int:
	# Visible contact can be displaced by the pony collision solver. Intent must
	# come from the tracked hand relative to the player, never that displacement.
	var motor_world:Vector3=world if tracked_world==null else tracked_world
	if not active or not motor_world.is_finite() or not world.is_finite() or not frame.is_finite() or not reference.is_finite() or delta<=0 or delta>.12:
		previous.erase(side)
		motion_previous.erase(side)
		latched.erase(side)
		armed.erase(side);contact_time.erase(side);motion_window.erase(side);latched_contact.erase(side)
		return _trace(side,"inactive_or_invalid_sample")
	var point:=frame.affine_inverse()*world
	var motor:=reference.affine_inverse()*motor_world
	if not previous.has(side):
		previous[side]=point;motion_previous[side]=motor;motion_window[side]=[];contact_time.erase(side)
		return _trace(side,"first_sample")
	var before:Vector3=previous[side];previous[side]=point
	var hand_travel:Vector3=reference.basis*(motor-motion_previous[side])
	motion_previous[side]=motor
	if before.distance_to(point)>.5 or hand_travel.length()>.5:
		advance_hand(side,world,delta,false)
		return _trace(side,"tracking_jump")
	# Average tracked motion over a short time window. Render/physics ticks can
	# observe the same XR pose twice; a zero-displacement tick is not a stopped swing.
	var window:Array=motion_window.get(side,[])
	window.append({"travel":hand_travel,"dt":delta})
	var duration:=0.0
	for entry:Dictionary in window:duration+=float(entry.dt)
	while window.size()>1 and duration-float(window[0].dt)>=MOTION_WINDOW:
		duration-=float(window[0].dt);window.pop_front()
	motion_window[side]=window
	var movement:=Vector3.ZERO
	for entry:Dictionary in window:movement+=Vector3(entry.travel)
	var velocity:Vector3=movement/maxf(duration,.0001)
	var withdrawn:=true
	if surface!=null:
		# Most connected ponies are nowhere near this hand. Do not skin their
		# contact patch merely because the broad 2.5m interaction guard passed.
		var mid:Vector3=(centers[0]+centers[1])*.5
		if point.distance_squared_to(mid)>.64 and before.distance_squared_to(mid)>.64:
			latched.erase(side);armed[side]=true;contact_time.erase(side)
			return _trace(side,"outside_hitboxes")
		if _surface_tick!=Engine.get_physics_frames():
			surface.update_pose(mare.skeleton,frame);_surface_tick=Engine.get_physics_frames()
		withdrawn=not surface.near(before,radii.z+WITHDRAWAL)
		if latched.get(side,false) and latched_contact.has(side):
			withdrawn=before.distance_to(latched_contact[side])>radii.z+WITHDRAWAL
	else:
		for i in centers.size():
			if _hitbox_point(before,i,WITHDRAWAL).length_squared()<=1.0:withdrawn=false;break
	if withdrawn:
		latched.erase(side);armed[side]=true;contact_time.erase(side)
	if latched.get(side,false) or not armed.get(side,false):return _trace(side,"withdraw_hand")
	if not palm.is_finite() or palm.length_squared()<.5:return _trace(side,"missing_palm")
	var hit:Dictionary={}
	var closest_index:=-1
	if surface!=null:
		var local_palm:Vector3=(frame.basis.inverse()*palm).normalized()
		hit=surface.contact(before,point,local_palm,radii.z)
		if not hit.is_empty():
			var n:Vector3=hit.normal
			closest_index=2 if n.z>absf(n.x) else (0 if n.x<0 else 1)
	else:
		# Analytic fixtures without a loaded body use their declared target planes.
		var earliest:=2.0
		var best_facing:=-1.0
		for i in centers.size():
			var outward:Vector3=(frame.basis.inverse().transposed()*normals[i]).normalized()
			best_facing=maxf(best_facing,palm.normalized().dot(-outward))
			if palm.normalized().dot(-outward)<.5:continue
			var t:=_hitbox_entry(before,point,i)
			if t>=0.0 and t<earliest:closest_index=i;earliest=t
		if closest_index>=0:hit={"position":before.lerp(point,earliest),"normal":normals[closest_index]}
		elif best_facing<.5:return _trace(side,"palm_direction",-1,-1.0,best_facing)
	if hit.is_empty():return _trace(side,"outside_hitboxes")
	var world_normal:Vector3=(frame.basis.inverse().transposed()*Vector3(hit.normal)).normalized()
	var facing:float=palm.normalized().dot(-world_normal)
	if facing<.5:return _trace(side,"palm_direction",-1,-1.0,facing)
	var strike_speed:float=-velocity.dot(world_normal)
	# The outer clearance is an approach region, not proof the palm has stopped
	# on the skin. Give an accelerating swing its short approach window; settled
	# slow contact still latches, so rubbing cannot become a repeated strike.
	contact_time[side]=float(contact_time.get(side,0.0))+delta
	if strike_speed<MIN_STRIKE_SPEED:
		if float(contact_time[side])<CONTACT_WINDOW:return _trace(side,"approaching",-1,strike_speed,facing)
		armed.erase(side);latched[side]=true
		latched_contact[side]=hit.position
		return _trace(side,"too_slow",-1,strike_speed,facing)
	armed.erase(side);latched[side]=true
	latched_contact[side]=hit.position
	last_hit=hit
	impact(closest_index,hit.position,strike_speed/3.0)
	return _trace(side,"accepted",closest_index,strike_speed,facing)

func _hitbox_point(point:Vector3,index:int,margin:float=0.0) -> Vector3:
	var normal:Vector3=normals[index]
	var up:=Vector3.UP.slide(normal).normalized()
	var across:=up.cross(normal).normalized()
	var offset:Vector3=point-centers[index]
	return Vector3(offset.dot(across),offset.dot(up),offset.dot(normal))/(radii+Vector3.ONE*margin)

func _hitbox_entry(before:Vector3,point:Vector3,index:int) -> float:
	var start:=_hitbox_point(before,index)
	var travel:=_hitbox_point(point,index)-start
	var c:=start.length_squared()-1.0
	if c<=0.0:return 0.0
	var a:=travel.length_squared()
	if a<.00000001:return -1.0
	var b:=start.dot(travel)
	var discriminant:=b*b-a*c
	if discriminant<0.0:return -1.0
	var t:=(-b-sqrt(discriminant))/a
	return t if t>=0.0 and t<=1.0 else -1.0

## Place the decal at the same coat intersection that accepted the strike.
## strength 0..1 scales the wobble (VR: palm speed into the coat; desktop clicks use the default).
func impact(index:int,at:=Vector3.INF,strength:=0.8) -> void:
	var started:=Time.get_ticks_usec()
	if _parked:wake_tick()  # refreshes frame and _local first
	if not (_fading or sound.playing):transform=_local
	_fading=true
	count+=1;ages[index]=0
	var centre:Vector3=at if at.is_finite() else centers[index]
	var normal:Vector3=normals[index]
	if at.is_finite() and not last_hit.is_empty() and at.is_equal_approx(last_hit.position):normal=last_hit.normal
	var across:=Vector3.UP.cross(normal).normalized()
	if across.length_squared()<.5:across=Vector3.RIGHT
	var basis:=Basis(across,normal,across.cross(normal)).orthonormalized()
	marks[index].transform=Transform3D(basis,centre+normal*.015)
	mark_attachments[index]=surface.attachment(last_hit) if surface!=null and at.is_finite() and not last_hit.is_empty() and at.is_equal_approx(last_hit.position) else []
	if not mark_attachments[index].is_empty():marks[index].transform=surface.attached_pose(mark_attachments[index],mare.skeleton,frame)
	marks[index].albedo_mix=.8;marks[index].visible=true   # same frame as the slap sound
	sound.position=centre;sound.play()
	_start_jiggle(index,strength)
	# A spa client on the table (W1-SPA): a VR smack or a palm rubbing her hind legs is massage, not
	# romantic contact, so no blush and no flank_smack reaction (that could end in a buck).
	var spa_client:bool=mare.has_meta("spa_client")
	if not spa_client:
		mare.boop_node.strong_blush_time=5.0
		mare.boop_node.sustain_blush()
	mare.expressions.touch("flank",.6,.20)
	var before_reaction:=Time.get_ticks_usec()
	if not spa_client:mare.physical_reaction.emit("flank_smack")
	var finished:=Time.get_ticks_usec()
	HITCH.mark("flank impact %d: %d us visuals+sound, %d us reaction handlers"%[index,before_reaction-started,finished-before_reaction])

func _start_jiggle(index:int,strength:float) -> void:
	if not is_instance_valid(_body):return
	if _jiggle_index>=0:_end_jiggle()   # a new slap restarts the wobble
	_own_body_materials()
	# Her coat is skinned to the body mesh's skeleton; the head and hair merge onto their own.
	var body_skeleton:=_body.get_node_or_null(_body.skeleton)
	for mi:MeshInstance3D in mare.find_children("*","MeshInstance3D",true,false):
		if mi.mesh==null or mi.get_node_or_null(mi.skeleton)!=body_skeleton:continue
		# Only her own coat: worn accessories may share one material between ponies.
		if not (mi==_body or mi.name.begins_with("Cutie mark") or mi.has_meta(NEAR_MESH_META)):continue
		for si in mi.mesh.get_surface_count():
			var active:=mi.get_active_material(si)
			var source:=active as StandardMaterial3D
			if source!=null and source.transparency==BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
				var twin:=_mark_twin(source)
				_borrowed_marks.append([mi,si,mi.get_surface_override_material(si),twin])
				mi.set_surface_override_material(si,twin)
				_jiggle_targets.append([twin,mi])
				continue
			var mat:=active as ShaderMaterial
			var coat:=_coat_entries(mi,si) if mi.has_meta(NEAR_MESH_META) else PackedFloat32Array()
			while mat!=null:
				if mat.shader in JIGGLE_SHADERS:
					_jiggle_targets.append([mat,mi])
					if not coat.is_empty():mat.set_shader_parameter("jiggle_entry",coat)
				mat=mat.next_pass as ShaderMaterial
	_jiggle_index=index;_jiggle_age=0.0
	_jiggle_amount=JIGGLE_MAX*clampf(strength,0.3,1.0)
	set_process(true)
	_process(0.0)

## The dressing gives every mesh with the same source material one shared material, so the
## folded wings wear the body's coat material; wobbling it moved the wing tips by the cheek.
## The body gets its own copy (and its own outline) the first time it is slapped. The copy's
## outline joins the pony's outline list so the outline-width setting still reaches it.
func _own_body_materials() -> void:
	for si in _body.mesh.get_surface_count():
		var mat:=_body.get_active_material(si) as ShaderMaterial
		if mat==null or mat.has_meta("jiggle_own"):continue
		var own:=mat.duplicate() as ShaderMaterial
		var hull:=mat.next_pass as ShaderMaterial
		if hull!=null:
			own.next_pass=hull.duplicate()
			var outlines:Variant=mare.get("_outline_materials")
			if outlines is Array and hull in outlines:(outlines as Array).append(own.next_pass)
		own.set_meta("jiggle_own",true)
		_body.set_surface_override_material(si,own)

## For a merged near mesh surface: 1 per palette entry whose source surface is her body mesh,
## 0 for the rest (folded wings and the dock merge into the same surface and must not wobble).
func _coat_entries(mi:MeshInstance3D,si:int) -> PackedFloat32Array:
	var mask:=PackedFloat32Array();mask.resize(NEAR_MESH_ENTRIES)
	var near:Dictionary=mare.get("_near") if mare.get("_near") is Dictionary else {}
	for entry:Dictionary in near.get("groups",[]):
		if entry.get("mi")!=mi:continue
		var outputs:Array=entry.group.variants[entry.variant].outputs
		if si>=outputs.size():break
		var sources:Array=outputs[si].entries
		for i in mini(sources.size(),NEAR_MESH_ENTRIES):
			if mare.get_node_or_null(sources[i][0])==_body:mask[i]=1.0
	return mask

## MARK_SHADER copy of a cutie-mark material, kept on the source so each pony builds it once.
## The twin holds the source only weakly (no reference cycle).
static func _mark_twin(source:StandardMaterial3D) -> ShaderMaterial:
	if source.has_meta("jiggle_twin"):return source.get_meta("jiggle_twin")
	var twin:=ShaderMaterial.new();twin.shader=MARK_SHADER
	twin.set_shader_parameter("albedo_texture",source.albedo_texture)
	twin.set_shader_parameter("albedo_color",source.albedo_color)
	twin.set_shader_parameter("roughness",source.roughness)
	twin.set_shader_parameter("uv1_scale",source.uv1_scale)
	twin.set_shader_parameter("uv1_offset",source.uv1_offset)
	source.set_meta("jiggle_twin",twin);twin.set_meta("jiggle_source",weakref(source))
	return twin

## Feeds the wobble its age and the slapped spot (the redness mark, which follows the skinned
## coat) in each mesh's space every rendered frame, then puts everything back.
func _process(delta:float) -> void:
	if _jiggle_index<0:
		set_process(false);return
	_jiggle_age+=delta
	if _jiggle_age>=JIGGLE_SECONDS:
		_end_jiggle();return
	var mark:Decal=marks[_jiggle_index]
	var outward:=mark.global_basis.y.normalized()
	var spot:=mark.global_position-outward*.015
	for target in _jiggle_targets:
		var mat:ShaderMaterial=target[0]
		var mi:MeshInstance3D=target[1]
		if not is_instance_valid(mat) or not is_instance_valid(mi):continue
		var to_mesh:=mi.global_transform.affine_inverse()
		mat.set_shader_parameter("jiggle_amount",_jiggle_amount)
		mat.set_shader_parameter("jiggle_time",_jiggle_age)
		mat.set_shader_parameter("jiggle_center",to_mesh*spot)
		mat.set_shader_parameter("jiggle_normal",(to_mesh.basis*outward).normalized())

func _end_jiggle() -> void:
	for target in _jiggle_targets:
		if not is_instance_valid(target[0]):continue
		for uniform in JIGGLE_UNIFORMS:(target[0] as ShaderMaterial).set_shader_parameter(uniform,null)
	for borrowed in _borrowed_marks:
		var mi:MeshInstance3D=borrowed[0]
		# A re-dress or LOD switch may have replaced the twin meanwhile; leave its choice alone.
		if is_instance_valid(mi) and mi.get_surface_override_material(borrowed[1])==borrowed[3]:
			mi.set_surface_override_material(borrowed[1],borrowed[2])
	_jiggle_targets.clear();_borrowed_marks.clear()
	_jiggle_index=-1
	set_process(false)

func _unprofiled_physics_process(delta:float) -> void:
	if not is_instance_valid(mare):return
	# Once every decal has faded (and the touch was released past 3 s) this pass changes nothing.
	if _fading:
		var shown:=false
		for i in ages.size():
			ages[i]+=delta
			marks[i].albedo_mix=.8*(1.0-smoothstep(1.0,FADE_SECONDS,ages[i]))
			marks[i].visible=ages[i]<FADE_SECONDS
			shown=shown or ages[i]<FADE_SECONDS
		if not ages.is_empty() and ages.min()>3.0:mare.expressions.release_touch("flank")
		_fading=shown
	if mare.sim_tier!=0:
		if diagnostics_enabled:
			for side in ["left","right"]:_trace(side,"simulation_tier_"+str(mare.sim_tier))
		elif not _fading and not sound.playing:_park()
		return  # clip tiers are beyond hand reach
	var boop:Node=mare.boop_node
	# No hands (desktop) and nothing left to forget: the per-side pass below would be a no-op.
	if boop._hands.is_empty() and previous.is_empty() and motion_previous.is_empty() and latched.is_empty() and armed.is_empty():return
	for side in ["left","right"]:
		var hand:Node3D=boop._hands.get(side)
		var controller:Node=boop._controllers.get(side)
		var tracked:bool=is_instance_valid(hand)
		if tracked:
			# A hand holding an equipped item still smacks (dev 2026-09-28: "ass smack doesn't work
			# anymore": the new hotbar keeps an item in hand).
			tracked=not mare.is_held() and not hand.get_meta("pony_inspection",false)
		if tracked and is_instance_valid(controller) and controller.has_method("get_is_active"):tracked=controller.get_is_active()
		if tracked and is_instance_valid(controller) and controller.has_method("get_has_tracking_data"):tracked=controller.get_has_tracking_data()
		if tracked and hand.global_position.distance_to(mare.global_position)<2.5:
			var source:Node3D=controller as Node3D if controller is Node3D else hand
			var palm:Vector3=-source.global_basis.y
			var contact:Vector3=source.global_position
			# Contact uses the same visible palm as hand collision; a controller origin
			# behind that palm may never cross the coat even during a real strike.
			if boop.hand_sampler.is_valid():
				var sample:Dictionary=boop.hand_sampler.call(side)
				if not sample.get("active",false):
					advance_hand(side,Vector3.ZERO,delta,false);continue
				palm=sample.get("palm",palm)
				contact=sample.get("grip_position",contact)
			var reference:=Transform3D.IDENTITY
			if source.get_parent() is Node3D:reference=source.get_parent().global_transform
			advance_hand(side,contact,delta,true,palm,reference,source.global_position)
		else:
			advance_hand(side,Vector3.ZERO,delta,false)
			if diagnostics_enabled:_trace(side,"hand_out_of_range" if tracked else "tracking_missing_or_held")


func _physics_process(delta:float) -> void:
	var started := Time.get_ticks_usec() if CROWD_PROFILE.enabled else 0
	_unprofiled_physics_process(delta)
	if CROWD_PROFILE.enabled: CROWD_PROFILE.record("flank_touch", started)
