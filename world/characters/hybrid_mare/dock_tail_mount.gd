extends RefCounted
## Locate the fixed tail collar in the shared body mesh frame, once per hair asset, and seat every
## adult mare's tail at the reference dock (Rainbow Dash's collar), so tail and dock meet the same
## way on every mare (ported from a community mod's tail seating, 2026-11-11).
const PATH:="res://world/characters/hybrid_mare/dock_tail_mounts.json"
## Hand trims of the seat: where each mare's collar goes from the reference and how her dock sits.
const TRIMS:="res://world/characters/hybrid_mare/tail_seat_trims.json"
## Pony meta once her tail is seated, all in body mesh space: {"collar": height of the middle of
## her collar after the move (NAN when unknown), "shift": her collar from the reference (Vector3),
## "dock_y", "dock_scale": her dock trims}. offset() is zero for her and hybrid_dock.gd builds the
## dock under that collar.
const SEATED:=&"tail_seated"
## Rollback and A/B (tools/characters/tail_seat_sheet.gd): false leaves each tail where its hair
## asset puts it and moves the dock to it, as before 2026-11-11. Read when a pony is built.
static var seat_enabled:=true
static var _baked:Dictionary={}
static var _trims:Dictionary={}
## Collar rows by hair asset key: {"anchor":[x,y,z],"cap_centre":y}, as built (never seated).
static var _cache:Dictionary={}
static func bind_for(mesh:MeshInstance3D,name:String)->Transform3D:
	# A hidden rig mesh lends its skeleton path out while parked (hybrid_mare.set_rig_parking).
	var sk:Skeleton3D=mesh.get_node(mesh.get_meta(&"parked_skeleton",mesh.skeleton))
	for i in mesh.skin.get_bind_count():
		var bone:=sk.find_bone(mesh.skin.get_bind_name(i))
		if bone<0:bone=mesh.skin.get_bind_bone(i)
		if sk.get_bone_name(bone)==name:return mesh.skin.get_bind_pose(i)
	return Transform3D.IDENTITY
static func measure(pony:Node)->Dictionary:
	if pony.hair==null or pony.hair_link==null:return {}
	var body:MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var tail:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail",true,false)
	if body==null or tail==null:return {}
	var transform:Transform3D=bind_for(body,"pony_hips").affine_inverse()*pony.hair_link.pelvis_offset*bind_for(tail,"mPelvis")
	var low:=Vector3.INF;var high:=-Vector3.INF;var count:=0
	for surface in tail.mesh.get_surface_count():
		var vertices:PackedVector3Array=tail.mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for i in tail.mesh.get_meta("pinned_"+str(surface),PackedInt32Array()):
			var p:Vector3=transform*vertices[i];low=low.min(p);high=high.max(p);count+=1
	if count==0:return {}
	var under:=Vector3((low.x+high.x)*.5,low.y,(low.z+high.z)*.5)
	return {"anchor":[under.x,under.y,under.z],"cap_centre":(low.y+high.y)*.5,"samples":count}
static func _load()->void:
	if _baked.is_empty() and FileAccess.file_exists(PATH):
		var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if parsed is Dictionary:_baked=parsed
## The reference collar anchor in body mesh space; not finite without the baked table.
static func reference_anchor()->Vector3:
	_load()
	var r:Variant=_baked.get("reference")
	return Vector3(r[0],r[1],r[2]) if r is Array and r.size()==3 else Vector3.INF
## The seat trims of one mare: the table's default with her own row over it.
static func trim(id:String)->Dictionary:
	if _trims.is_empty() and FileAccess.file_exists(TRIMS):
		var parsed:Variant=JSON.parse_string(FileAccess.get_file_as_string(TRIMS))
		if parsed is Dictionary:_trims=parsed
	var result:Dictionary=_trims.get("default",{}).duplicate()
	result.merge(_trims.get("mares",{}).get(id,{}),true)
	return result
## Her collar as her hair asset mounts it: the baked row while it matches the asset, else measured.
## Only read before seat() moves her tail; the result is kept per hair asset. {} with no tail.
static func row(pony:Node)->Dictionary:
	_load()
	var id:String=pony.identity.id
	var tail:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail",true,false) if pony.hair!=null else null
	if tail==null:return {}
	var version:int=tail.mesh.get_meta("anchor_version",0)
	var mount:Vector3=pony.identity.tail_mount_offset
	var mtime:=FileAccess.get_modified_time(pony.identity.hair_scene)
	var key:String=id+str(mount)+str(mtime)+String(pony.identity.hair_scene)+str(version)
	if _cache.has(key):return _cache[key]
	var data:Dictionary=_baked.get("ponies",{}).get(id,{})
	if not data.has("cap_centre") or data.get("source","")!=pony.identity.hair_scene or data.get("mtime",-1)!=mtime or data.get("mount",[])!=[mount.x,mount.y,mount.z] or data.get("anchor_version",-1)!=version:
		data=measure(pony)
	if not data.is_empty():_cache[key]=data
	return data
## How far her collar is from the reference, in body mesh space. Zero once she is seated.
static func offset(pony:Node)->Vector3:
	if pony.has_meta(SEATED):return Vector3.ZERO
	var target:=reference_anchor()
	if not target.is_finite():return Vector3.ZERO
	var data:=row(pony)
	if data.is_empty():return Vector3.ZERO
	var a:Array=data.anchor
	return Vector3(a[0],a[1],a[2])-target
## Moves her hair tail so its collar sits at the reference, plus her trim. Adult mares only: the reference is a
## point on the mare body, so stallions and fillies keep the mounts their hair assets give them.
## Runs once, when she is built, after the hair link is bound and before the dock is made.
static func seat(pony:Node)->void:
	if not seat_enabled or pony.has_meta(SEATED) or pony.identity.filly or pony.identity.stallion:return
	if pony.hair==null or pony.hair_link==null:return
	var body:MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var target:=reference_anchor()
	if body==null or body.skin==null or not target.is_finite():return
	var data:=row(pony)
	if data.is_empty():return
	var a:Array=data.anchor
	var own:=trim(pony.identity.id)
	var shift:=Vector3(0.0,float(own.get("tail_y",0.0)),float(own.get("tail_z",0.0)))
	var delta:=target+shift-Vector3(a[0],a[1],a[2])
	# anchor = hips_bind^-1 * pelvis_offset * tail_bind * vertex, so a move of `delta` in body mesh
	# space is hips_bind.basis * delta on the link's offset.
	var link_offset:Transform3D=pony.hair_link.pelvis_offset
	link_offset.origin+=bind_for(body,"pony_hips").basis*delta
	pony.hair_link.pelvis_offset=link_offset
	pony.set_meta(SEATED,{"collar":float(data.get("cap_centre",NAN))+delta.y,"shift":shift,
		"dock_y":float(own.get("dock_y",0.0)),"dock_scale":float(own.get("dock_scale",1.0))})
