extends RefCounted
## Native OpenPony dock, with its hidden base seated in the native rump.
## The existing fixed tail collar and this dock share the pelvis; free hair keeps its jiggle.
const MESH := preload("res://world/characters/hybrid_mare/openpony_dock.res")
const FIT_PATH := "user://character_fits/openpony_dock.json"
const APPROVED_FIT_PATH := "res://world/characters/hybrid_mare/dock_fit.json"
const TAIL_MOUNT:=preload("res://world/characters/hybrid_mare/dock_tail_mount.gd")
## A pony whose tail is not seated at the reference (stallions, a mare whose collar cannot be
## measured) has her dock moved to her tail, then this far back: the median of the 46 hand fits
## that preceded the tail seat, so the dock clears the body instead of sitting buried in it (dev
## 2026-11-04: Cheerilee and Shoeshine). Those hand fits are in the archive (dock-seat-2026-11-11).
const VISIBILITY_FALLBACK:=Vector3(0.0,0.0,0.04)
## Rear midline in rest pose, sampled at X=0 every RUMP_STEP_Y from RUMP_FIRST_Y
## (tools/characters/measure_rump.gd). Run it again when a body changes. The rump curves forward as
## it rises, so a high tail mount can leave the dock's base ring clear of the body. The last value is
## an estimate: at that height the ray passes over the top of the rump. Stallions have their own
## body, up to 2.2 cm further back near the top; fillies have no dock stretch.
const RUMP_FIRST_Y:=0.44
const RUMP_STEP_Y:=0.02
const RUMP_Z:={
	"mare":[0.2684,0.2777,0.2835,0.2867,0.2881,0.2885,0.2880,0.2857,0.2789,0.2604,0.2188,0.1],
	"stallion":[0.2833,0.2915,0.2951,0.2956,0.2948,0.2931,0.2908,0.2875,0.2819,0.2681,0.2409,0.1],
}
const RUMP_MIN_GAP:=0.012
const RUMP_EMBED:=0.004
const RUMP_MAX_REACH:=0.08
## Share of the dock's length, from its base, over which the base ring's move to the rump fades.
const SNAP_FALLOFF:=0.35
static var _approved_fit:Dictionary={}
static var _meshes:Dictionary={}
## Docks under a seated tail, by fit and collar height (millimetres).
static var _seated:Dictionary={}
## Stretched docks, by fitted mesh and body: an identity's dock is built once.
static var _reached:Dictionary={}
static func defaults()->Dictionary:
	return {"version":1,"position":[0.0,0.0,0.0],"rotation_degrees":[0.0,0.0,0.0],"scale":1.0,"scale_xyz":[1.0,1.0,1.0]}
static func valid(data:Variant)->bool:
	if not data is Dictionary or data.get("version")!=1:return false
	for key in ["position","rotation_degrees"]:
		if not data.get(key) is Array or data[key].size()!=3:return false
		for value in data[key]:
			if not (value is float or value is int) or not is_finite(float(value)):return false
	if not (data.get("scale") is float or data.get("scale") is int):return false
	var axes:Variant=data.get("scale_xyz",[1.0,1.0,1.0])
	if not axes is Array or axes.size()!=3:return false
	for value in axes:
		if not (value is float or value is int) or not is_finite(float(value)) or float(value)<.05 or float(value)>10:return false
	return float(data.scale)>=.1 and float(data.scale)<=5 and vector(data.position).length()<=2
static func vector(values:Array)->Vector3:return Vector3(values[0],values[1],values[2])
static func read_fit(path:String=FIT_PATH)->Dictionary:
	if path==FIT_PATH and not FileAccess.file_exists(path):path=APPROVED_FIT_PATH
	if not FileAccess.file_exists(path):return defaults()
	var data:Variant=JSON.parse_string(FileAccess.get_file_as_string(path))
	if not valid(data):return defaults()
	if not data.has("scale_xyz"):data.scale_xyz=[1.0,1.0,1.0]
	return data
static func save_fit(data:Dictionary,path:String=FIT_PATH)->Error:
	if not valid(data):return ERR_INVALID_DATA
	var error:=DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if error!=OK:return error
	var file:=FileAccess.open(path+".tmp",FileAccess.WRITE)
	if file==null:return FileAccess.get_open_error()
	file.store_string(JSON.stringify(data,"\t",true,true));file.flush();file.close()
	# Atomic replacement, retaining the previous accepted placement for recovery.
	if FileAccess.file_exists(path):
		error=DirAccess.copy_absolute(path,path+".previous")
		if error!=OK:return error
	return DirAccess.rename_absolute(path+".tmp",path)
static func pivot()->Vector3:
	var vertices:PackedVector3Array=MESH.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var result:=Vector3.ZERO;var indices:PackedInt32Array=MESH.get_meta("base_indices")
	for i in indices:result+=vertices[i]
	return result/maxi(1,indices.size())
static func fit_transform(data:Dictionary)->Transform3D:
	var rotation:=Basis.from_euler(vector(data.rotation_degrees)*PI/180.0).scaled_local(vector(data.get("scale_xyz",[1.0,1.0,1.0]))*float(data.scale))
	var center:=pivot()
	return Transform3D(rotation,center+vector(data.position)-rotation*center)
static func fitted_mesh(data:Dictionary,cache:bool=true)->ArrayMesh:
	if data==defaults():return MESH
	var key:=JSON.stringify(data)
	if cache and _meshes.has(key):return _meshes[key]
	var arrays:=MESH.surface_get_arrays(0)
	var transform:=fit_transform(data)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var normals:PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
	var normal_basis:=transform.basis.inverse().transposed()
	for i in vertices.size():
		vertices[i]=transform*vertices[i];normals[i]=(normal_basis*normals[i]).normalized()
	arrays[Mesh.ARRAY_VERTEX]=vertices;arrays[Mesh.ARRAY_NORMAL]=normals
	var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	for meta in MESH.get_meta_list():mesh.set_meta(meta,MESH.get_meta(meta))
	mesh.set_meta("user_fit",data.duplicate(true))
	if cache:_meshes[key]=mesh
	return mesh
static func preview(pony:Node,data:Dictionary)->void:
	var dock:MeshInstance3D=pony.find_child("OpenPonyDock",true,false)
	if dock!=null:dock.mesh=dock_mesh(pony,data,false)
static func rump_z(body:String,y:float)->float:
	var table:Array=RUMP_Z[body]
	var at:=clampf((y-RUMP_FIRST_Y)/RUMP_STEP_Y,0.0,table.size()-1.0)
	var low:=mini(floori(at),table.size()-2)
	return lerpf(float(table[low]),float(table[low+1]),at-low)
## The dock with its base ring pushed forward into the rump and its tail end where it was: a longer
## dock, same height. Bodies with no table, and a dock already touching, keep the mesh as it is.
static func reach_rump(fitted:ArrayMesh,pony:Node,cache:bool=true)->ArrayMesh:
	if pony.identity.filly:return fitted
	var body:="stallion" if pony.identity.stallion else "mare"
	var key:="%d:%s"%[fitted.get_instance_id(),body]
	if cache and _reached.has(key):return _reached[key]
	var result:=_stretched(fitted,body)
	if cache:_reached[key]=result
	return result
static func _stretched(fitted:ArrayMesh,body:String)->ArrayMesh:
	var arrays:=fitted.surface_get_arrays(0)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var ring:PackedInt32Array=fitted.get_meta("base_indices")
	var base:=Vector3.ZERO;var front:=Vector3.INF
	for i in ring:
		base+=vertices[i]
		if vertices[i].z<front.z:front=vertices[i]
	base/=maxi(1,ring.size())
	var tip:=base
	for vertex in vertices:
		if vertex.distance_squared_to(base)>tip.distance_squared_to(base):tip=vertex
	var length:=base.distance_to(tip)
	var gap:=front.z-rump_z(body,front.y)
	if length<.001 or gap<RUMP_MIN_GAP:return fitted
	var axis:=(tip-base)/length
	var reach:=minf(gap+RUMP_EMBED,RUMP_MAX_REACH)
	for i in vertices.size():
		vertices[i].z-=reach*(1.0-clampf((vertices[i]-base).dot(axis)/length,0.0,1.0))
	arrays[Mesh.ARRAY_VERTEX]=vertices
	var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	for meta in fitted.get_meta_list():mesh.set_meta(meta,fitted.get_meta(meta))
	mesh.set_meta("rump_reach",reach)
	return mesh
static func same_fit(a:Dictionary,b:Dictionary)->bool:
	if not valid(a) or not valid(b):return false
	# JSON writers round the accepted doubles differently. Compare physical values,
	# so a serialization round-trip cannot silently disable the roster fitting.
	if absf(float(a.scale)-float(b.scale))>1e-9:return false
	for key in ["position","rotation_degrees","scale_xyz"]:
		var av:Array=a.get(key,[1.0,1.0,1.0])
		var bv:Array=b.get(key,[1.0,1.0,1.0])
		for i in 3:
			if absf(float(av[i])-float(bv[i]))>1e-9:return false
	return true
## The dock with every base ring vertex on the rump (RUMP_EMBED inside it), the move fading over
## the first SNAP_FALLOFF of the dock so the base stretches into the coat instead of creasing, and
## the normals rebuilt. reach_rump only brings the frontmost vertex in, which left most of the ring
## 5 to 33 mm behind the rump (ported from a community mod's dock seat, 2026-11-11).
static func snap_base(mesh:ArrayMesh,body:String)->ArrayMesh:
	var ring:PackedInt32Array=mesh.get_meta("base_indices",PackedInt32Array())
	if ring.is_empty() or not RUMP_Z.has(body):return mesh
	var arrays:=mesh.surface_get_arrays(0)
	var vertices:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
	var base:=Vector3.ZERO
	for i in ring:base+=vertices[i]
	base/=ring.size()
	var tip:=base
	for vertex in vertices:
		if vertex.distance_squared_to(base)>tip.distance_squared_to(base):tip=vertex
	var length:=base.distance_to(tip)
	if length<.001:return mesh
	var axis:=(tip-base)/length
	var moves:=PackedFloat32Array();moves.resize(vertices.size())
	var on_ring:=PackedByteArray();on_ring.resize(vertices.size())
	for i in ring:
		moves[i]=rump_z(body,vertices[i].y)-RUMP_EMBED-vertices[i].z;on_ring[i]=1
	for i in vertices.size():
		if on_ring[i]==1:continue
		var fade:=1.0-smoothstep(0.0,SNAP_FALLOFF,clampf((vertices[i]-base).dot(axis)/length,0.0,1.0))
		if fade<=0.0:continue
		var nearest:=ring[0]
		for r in ring:
			if vertices[i].distance_squared_to(vertices[r])<vertices[i].distance_squared_to(vertices[nearest]):nearest=r
		moves[i]=moves[nearest]*fade
	for i in vertices.size():vertices[i].z+=moves[i]
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=_smooth_normals(vertices,arrays[Mesh.ARRAY_INDEX],arrays[Mesh.ARRAY_NORMAL])
	var result:=ArrayMesh.new();result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	for meta in mesh.get_meta_list():result.set_meta(meta,mesh.get_meta(meta))
	result.set_meta("base_snapped",true)
	return result
## Area-weighted normals of the moved dock. Vertices doubled along a texture seam share one normal,
## so the seam does not show in the cel bands; the authored normals decide which way is out.
static func _smooth_normals(vertices:PackedVector3Array,indices:PackedInt32Array,authored:PackedVector3Array)->PackedVector3Array:
	var sums:={}
	for t in range(0,indices.size(),3):
		var a:=vertices[indices[t]];var b:=vertices[indices[t+1]];var c:=vertices[indices[t+2]]
		var face:=(b-a).cross(c-a)
		for point:Vector3 in [a,b,c]:
			var key:Vector3i=Vector3i((point*100000.0).round())
			sums[key]=sums.get(key,Vector3.ZERO)+face
	var normals:=PackedVector3Array();normals.resize(vertices.size())
	var agreement:=0.0
	for i in vertices.size():
		var sum:Vector3=sums.get(Vector3i((vertices[i]*100000.0).round()),Vector3.ZERO)
		normals[i]=sum.normalized() if sum.length_squared()>1e-20 else authored[i]
		agreement+=normals[i].dot(authored[i])
	if agreement<0.0:
		for i in normals.size():normals[i]=-normals[i]
	return normals
## The dock mesh this pony wears for the fit `data`. Under a seated tail (dock_tail_mount.seat) that
## is the fit moved with her collar and sized by her trim, raised or lowered so its top meets the
## middle of the collar plus her dock_y trim, with the base ring on the rump at that height. Other
## ponies keep the dock moved to their tail.
static func dock_mesh(pony:Node,data:Dictionary,cache:bool=true)->ArrayMesh:
	var fit:=effective_fit(pony,data)
	if not pony.has_meta(TAIL_MOUNT.SEATED):return reach_rump(fitted_mesh(fit,cache),pony,cache)
	var seat:Dictionary=pony.get_meta(TAIL_MOUNT.SEATED)
	if not is_equal_approx(float(seat.dock_scale),1.0):
		fit=fit.duplicate(true);fit.scale=float(fit.scale)*float(seat.dock_scale)
	var collar:float=float(seat.collar)+float(seat.dock_y)
	var key:="%s|%d"%[JSON.stringify(fit),roundi(collar*1000.0) if is_finite(collar) else -1]
	if cache and _seated.has(key):return _seated[key]
	var mesh:=snap_base(_stretched(fitted_mesh(fit,cache),"mare"),"mare")
	var lift:=snappedf(collar-mesh.get_aabb().end.y,0.001) if is_finite(collar) else 0.0
	if not is_zero_approx(lift):
		var raised:=fit.duplicate(true)
		raised.position=[float(fit.position[0]),float(fit.position[1])+lift,float(fit.position[2])]
		mesh=snap_base(_stretched(fitted_mesh(raised,false),"mare"),"mare")
	if cache:_seated[key]=mesh
	return mesh
static func effective_fit(pony:Node,data:Dictionary)->Dictionary:
	var offset:Vector3
	if pony.has_meta(TAIL_MOUNT.SEATED):
		# A seated tail is at the reference plus her trim: the dock goes with it, at its own size.
		offset=pony.get_meta(TAIL_MOUNT.SEATED).shift
	else:
		offset=TAIL_MOUNT.offset(pony)
		if _approved_fit.is_empty():_approved_fit=read_fit(APPROVED_FIT_PATH)
		# Only adapt the accepted reference shape. A new user gizmo edit retains
		# direct control and is not silently altered by an offset fitted to older art.
		if same_fit(data,_approved_fit) and pony.identity.id!="rainbow_dash" and not pony.identity.filly:offset+=VISIBILITY_FALLBACK
	if offset.length_squared()<1e-12:return data
	var adapted:=data.duplicate(true)
	var position:=vector(data.position)+offset
	adapted.position=[position.x,position.y,position.z]
	return adapted
static func posed_frame(pony:Node)->Transform3D:
	# Mesh offsets are baked before skinning, so they remain pelvis-local in every pose.
	var body:MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var hips:int=pony.skeleton.find_bone("pony_hips")
	for i in body.skin.get_bind_count():
		if body.skin.get_bind_name(i)==&"pony_hips" or (body.skin.get_bind_name(i)==&"" and body.skin.get_bind_bone(i)==hips):
			return pony.skeleton.global_transform*pony.skeleton.get_bone_global_pose(hips)*body.skin.get_bind_pose(i)
	return pony.skeleton.global_transform
static func apply(pony: Node,path:String=FIT_PATH) -> void:
	TAIL_MOUNT.seat(pony)
	var body: MeshInstance3D=pony._model.find_child("MareBody",true,false)
	var dock:MeshInstance3D=pony.find_child("OpenPonyDock",true,false)
	if dock==null:
		dock=MeshInstance3D.new();dock.name="OpenPonyDock";pony.skeleton.add_child(dock);dock.skeleton=dock.get_path_to(pony.skeleton)
	dock.mesh=dock_mesh(pony,read_fit(path));dock.skin=body.skin
	dock.set_surface_override_material(0,body.get_active_material(0))
	if body.has_meta("source_material_0"):dock.set_meta("source_material_0",body.get_meta("source_material_0"))
