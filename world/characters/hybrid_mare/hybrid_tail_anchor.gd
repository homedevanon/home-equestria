extends RefCounted
## Fix the actual hair collar to mPelvis, independently of all simulated joints.
## Derived shared meshes retain the original geometry, materials and eight-weight skin.
const VERSION := 1
const DIRECTORY := "res://world/characters/hybrid_mare/tail_anchors/"
static var cache:Dictionary={}

static func apply(pony:Node)->void:
	for suffix in ["", "LOD1"]:
		var mi:MeshInstance3D=pony.hair.find_child(pony.identity.hair_prefix+"DevkitTail"+suffix,true,false)
		if mi==null:continue
		var key:String=String(pony.identity.id)+suffix
		var path:=DIRECTORY+key+".res"
		var derived:ArrayMesh
		derived=cache.get(key)
		if derived==null and ResourceLoader.exists(path):
			var candidate:ArrayMesh=load(path)
			# Inside an exported pack the hair scene has no file time, so the staleness check
			# rejected every cached anchor and rebuilt at runtime (2026-09-29: a release build
			# crashed on Twilight's tail). Exports trust the shipped cache.
			# In a source run with any mod pack mounted every res:// file time reads 0 (2026-11-23):
			# 0 is "unknown", not "changed". Counting it as changed rebuilt every Mane 6 tail at run
			# time and threw away the lighter tails of a hair pack.
			var stamp:=FileAccess.get_modified_time(pony.identity.hair_scene)
			var stale:bool=OS.has_feature("editor") and stamp>0 and int(candidate.get_meta("source_mtime",-1))!=stamp
			if candidate.get_meta("anchor_version",-1)==VERSION and candidate.get_meta("source","")==pony.identity.hair_scene and not stale:derived=candidate
		if derived==null:derived=build(mi,pony.hair_skeleton,pony.pivot.global_basis*Vector3.BACK)
		derived.set_meta("anchor_version",VERSION)
		derived.set_meta("source",pony.identity.hair_scene)
		derived.set_meta("source_mtime",FileAccess.get_modified_time(pony.identity.hair_scene))
		# A saved mesh embeds material copies. Restore the imported shared instances
		# so mane/tail colours still batch together in the merged distant mesh.
		for surface in mi.mesh.get_surface_count():
			derived.surface_set_material(surface,mi.mesh.surface_get_material(surface))
		cache[key]=derived
		mi.mesh=derived

static func build(mi:MeshInstance3D,sk:Skeleton3D,back:Vector3)->ArrayMesh:
	var root_bind:=-1;var mount_bind:=-1
	var rest:Array[Transform3D]=[]
	for b in mi.skin.get_bind_count():
		var bone:=sk.find_bone(mi.skin.get_bind_name(b))
		if bone<0:bone=mi.skin.get_bind_bone(b)
		if sk.get_bone_name(bone)=="mTail1":root_bind=b
		if sk.get_bone_name(bone)=="mPelvis":mount_bind=b
		rest.append(sk.global_transform*sk.get_bone_global_rest(bone)*mi.skin.get_bind_pose(b))
	assert(root_bind>=0 and mount_bind>=0)
	var front:=INF
	var surfaces:Array=[];var coordinates:Array=[];var root_weights:Array=[]
	for surface in mi.mesh.get_surface_count():
		var arrays:=mi.mesh.surface_get_arrays(surface)
		var verts:PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var ids:PackedInt32Array=arrays[Mesh.ARRAY_BONES];var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var stride:int=ids.size()/verts.size()
		var coords:PackedFloat32Array=[];var roots:PackedFloat32Array=[]
		for v in verts.size():
			var point:=Vector3.ZERO;var root_weight:=0.
			for i in stride:
				var bind_id:=ids[v*stride+i];var weight:=weights[v*stride+i]
				point+=(rest[bind_id]*verts[v])*weight
				if bind_id==root_bind:root_weight+=weight
			var coordinate:=point.dot(back)
			coords.append(coordinate);roots.append(root_weight)
			if root_weight>.9:front=minf(front,coordinate)
		surfaces.append(arrays);coordinates.append(coords);root_weights.append(roots)
	var result:=ArrayMesh.new();var pinned:=0;var blended:=0
	for s in surfaces.size():
		var arrays:Array=surfaces[s]
		var ids:PackedInt32Array=arrays[Mesh.ARRAY_BONES];var weights:PackedFloat32Array=arrays[Mesh.ARRAY_WEIGHTS]
		var stride:int=ids.size()/arrays[Mesh.ARRAY_VERTEX].size()
		var fixed_vertices:=PackedInt32Array()
		for v in arrays[Mesh.ARRAY_VERTEX].size():
			# Pin the first 12 mm of the existing root cap, then ease to the
			# original articulated skin over 55 mm. Distal strands remain free.
			var pin:float=(1.-smoothstep(front+.012,front+.067,coordinates[s][v]))*smoothstep(0.,.5,root_weights[s][v])
			if pin<=.000001:continue
			var merged:Dictionary={mount_bind:pin}
			for i in stride:
				var weight:=weights[v*stride+i]*(1.-pin)
				if weight>.000001:
					var bone:=ids[v*stride+i];merged[bone]=merged.get(bone,0.)+weight
			# More influences than the skin holds: drop the lightest ones (a release build has
			# no assert and would write past the vertex's slots).
			while merged.size()>stride:
				var lightest:Variant=null
				for bone in merged:
					if bone==mount_bind:continue
					if lightest==null or merged[bone]<merged[lightest]:lightest=bone
				if lightest==null:break
				merged.erase(lightest)
			for i in stride:ids[v*stride+i]=0;weights[v*stride+i]=0.
			var i:=0;var total:=0.
			for bone in merged:total+=merged[bone]
			for bone in merged:
				ids[v*stride+i]=bone;weights[v*stride+i]=merged[bone]/total;i+=1
			if pin>.99999:fixed_vertices.append(v);pinned+=1
			else:blended+=1
		arrays[Mesh.ARRAY_BONES]=ids;arrays[Mesh.ARRAY_WEIGHTS]=weights
		result.add_surface_from_arrays(mi.mesh.surface_get_primitive_type(s),arrays,[],{},mi.mesh.surface_get_format(s)&Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS)
		result.surface_set_material(s,mi.mesh.surface_get_material(s))
		result.surface_set_name(s,mi.mesh.surface_get_name(s))
		result.set_meta("pinned_"+str(s),fixed_vertices)
	result.set_meta("pinned_count",pinned);result.set_meta("blended_count",blended)
	# Only transplant the new skin buffer and its bone bounds into the original
	# serialized surfaces: keeps positions, compressed normals and every index LOD
	# byte-identical, without decoding backend-specific LOD dictionaries.
	var original:Array=mi.mesh.call("_get_surfaces").duplicate(true)
	var changed:Array=result.call("_get_surfaces")
	for s in original.size():
		original[s]["skin_data"]=changed[s]["skin_data"]
		original[s]["bone_aabbs"]=changed[s]["bone_aabbs"]
	var preserved:=ArrayMesh.new()
	preserved.call("_set_surfaces",original)
	for key in result.get_meta_list():preserved.set_meta(key,result.get_meta(key))
	return preserved
