extends Node3D
## Detailed trees use 32 m batches; the last (far) level uses 512 m far tiles, and past
## tree_impostors.gd's hand-over (500 m) a baked two-triangle impostor where one exists.
## Each near batch and its far span share one range center, with no size multiplier.
const SPAN := 32.0
const CPU_PROFILE := preload("res://tools/crowd_cpu_profile.gd")
const FAR_SPAN := 512.0
const FAR_REBUILD_MS := 2000
const IMPOSTORS := preload("res://world/foliage/impostors/tree_impostors.gd")
## painted_lod meta of impostor instances (0-2 are the mesh levels).
const IMPOSTOR_LOD := 3
var asset_parts: Callable
var asset_lods: Callable
var batches: Dictionary = {}
var dirty: Dictionary = {}
## far cell -> {"node", "species": [{"spans": [{start, count, centre, threshold, state, reach}],
## "meshes": [[MultiMeshInstance3D, span buffer slices]], "impostor": [] or [MultiMeshInstance3D, slices]}]}
var far: Dictionary = {}
var far_dirty: Dictionary = {}
## far key -> {batch key: true}, in batch creation order, so _flush_far skips the other tiles.
var far_index: Dictionary = {}
## Returns true while the owner is still building cells; far tiles then rebuild at most every FAR_REBUILD_MS.
var streaming: Callable
var _far_flushed_at: Dictionary = {}
var _flushes := 0
var _far_budget_deferred := false
var _impostor_from := IMPOSTORS.from
var _far_selection_dirty := true
var _far_eye := Vector3.INF
var _far_margin_squared := 0.0
## dev 2026-10-20 multithreading: PonyFoliageFill (set by biome_foliage.gd while its native fill is on)
## packs the MultiMesh buffers and merges the bounds in C++, the same floats as the GDScript loops
## below; null keeps those loops.
var native: Object = null

## Impostor hand-over distance from the quality tier (impostor_from: 500 m, Medium 300, Low 180,
## Very Low 110); _process re-syncs every far tile when IMPOSTORS.from moves.
func _ready() -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return
	quality.preset_changed.connect(_apply_quality)
	_apply_quality(0)

func _apply_quality(_preset: int) -> void:
	var quality := get_node_or_null("/root/Quality")
	if quality == null: return
	var wanted := float(quality.get_value("impostor_from", IMPOSTORS.FROM))
	if not is_equal_approx(wanted, IMPOSTORS.from): IMPOSTORS.set_from(wanted)
## Off: far tiles never switch to impostors (overhead captures, where view-facing quads collapse).
var impostors := true
# Distant cells need their far tile, not thousands of invisible detailed instances.
# Keep the exact same meshes/ranges, creating them before the camera reaches them.
const DETAIL_MARGIN := 64.0
var _detail_cells := {}
var _detail_eye := Vector3.INF
var _detail_reach := 160.0

## Lane memory 2026-11-21: a batch holding one cell shares that cell's transform array with its
## near and far groups instead of a merged copy (High kept every tree of the 12 km reach twice).
## false = the old copy.
const SHARE_SINGLE_CELL := true
## Test hook (tools/profile/test_tree_share.gd compares both paths); play uses the constant.
static var share_single_cell := SHARE_SINGLE_CELL
func _key(cell: Vector2i) -> Vector2i:return cell
func _far_key(key: Vector2i) -> Vector2i:return Vector2i(floori(key.x/16.0),floori(key.y/16.0))

func put(cell: Vector2i, groups: Dictionary) -> void:
	if groups.is_empty():erase(cell);return
	var key:=_key(cell)
	if not batches.has(key):
		batches[key]={"cells":{},"node":null,"far_groups":{}}
		var fkey:=_far_key(key)
		if not far_index.has(fkey):far_index[fkey]={}
		far_index[fkey][key]=true
	batches[key].cells[cell]=groups;dirty[key]=true

func erase(cell: Vector2i) -> void:
	var key:=_key(cell)
	if batches.has(key):batches[key].cells.erase(cell);dirty[key]=true

## Flushes at least `minimum` near batches. Negative budget keeps unbudgeted behavior.
## A ready far tile may defer once when the remaining budget is exhausted.
func flush_one(minimum := 1, budget_usec := -1) -> void:
	_flushes+=1
	var until:=Time.get_ticks_usec()+maxi(0,budget_usec)
	if not dirty.is_empty():
		var done:=0
		while not dirty.is_empty() and (done<minimum or Time.get_ticks_usec()<until):
			var key: Vector2i=_first(dirty);dirty.erase(key)
			_flush_near(key);far_dirty[_far_key(key)]=true;done+=1
	# Far tiles wait for their batches to settle, so streaming does not rebuild it repeatedly.
	if far_dirty.is_empty():
		_far_budget_deferred=false
		return
	var fkey: Vector2i=_first(far_dirty)
	if streaming.is_valid() and streaming.call():
		# One near flush per frame empties `dirty` during the fill, so the %4 rule never held a tile back.
		var now:=Time.get_ticks_msec();var ready:=false
		for candidate: Vector2i in far_dirty:
			if now-int(_far_flushed_at.get(candidate,-FAR_REBUILD_MS))>=FAR_REBUILD_MS:fkey=candidate;ready=true;break
		if not ready:return
	elif not dirty.is_empty() and _flushes%4!=0:return
	# Do not stack far work on an exhausted fill frame, but guarantee progress
	# on the next eligible call even when streaming continually uses the budget.
	if budget_usec>=0 and Time.get_ticks_usec()>=until and not _far_budget_deferred:
		_far_budget_deferred=true
		return
	_far_budget_deferred=false
	far_dirty.erase(fkey);_far_flushed_at[fkey]=Time.get_ticks_msec()
	_flush_far(fkey)

## First key in insertion order, without copying keys() of a large dictionary.
static func _first(keys: Dictionary) -> Vector2i:
	for key: Vector2i in keys:return key
	return Vector2i.ZERO

func _flush_near(key: Vector2i) -> void:
	var record: Dictionary=batches[key]
	var merged:={}
	if share_single_cell and record.cells.size()==1 and record.cells.has(key):
		# The batch is its own cell (_key is the identity): the merge would copy every transform
		# with a zero shift. Share the cell's array instead; only -0.0 origin components become
		# +0.0, as the old copy made them.
		for id: String in record.cells[key]:
			var group: Dictionary=record.cells[key][id]
			var transforms: Array=group.transforms
			for i in transforms.size():
				var o: Vector3=(transforms[i] as Transform3D).origin
				if o.x==0.0 or o.y==0.0 or o.z==0.0:
					var shifted: Transform3D=transforms[i];shifted.origin+=Vector3.ZERO;transforms[i]=shifted
			merged[id]={"entry":group.entry,"transforms":transforms}
	else:
		for cell: Vector2i in record.cells:
			for id: String in record.cells[cell]:
				var group: Dictionary=record.cells[cell][id]
				if not merged.has(id):merged[id]={"entry":group.entry,"transforms":[]}
				for source: Transform3D in group.transforms:
					var transform:=source;transform.origin+=Vector3(cell.x*32-key.x*SPAN,0,cell.y*32-key.y*SPAN)
					merged[id].transforms.append(transform)
	var offset := Vector3(key.x*SPAN,0,key.y*SPAN)
	if is_instance_valid(record.node): record.node.queue_free()
	record.node = null; _detail_cells.erase(key)
	record.far_groups={}; record["near_groups"] = []
	for group: Dictionary in merged.values():
		var levels:Array=asset_lods.call(group.entry) if asset_lods.is_valid() else []
		if levels.is_empty():levels=[{"parts":asset_parts.call(group.entry),"begin":0.0,"end":0.0}]
		var shared_bounds:=AABB()
		var first:=true
		var scale:=1.0
		for source:Transform3D in group.transforms:
			scale=maxf(scale,maxf(source.basis.x.length(),maxf(source.basis.y.length(),source.basis.z.length())))
		for level:Dictionary in levels:
			for part:Array in level.parts:
				var local:AABB=part[0].get_aabb();var placement:Transform3D=part[1]
				if native!=null:
					var native_bounds:Array=native.merge_bounds(shared_bounds,first,group.transforms,placement,local,true)
					shared_bounds=native_bounds[0];first=native_bounds[1];continue
				for source:Transform3D in group.transforms:
					var box:AABB=(source*placement)*local
					shared_bounds=box if first else shared_bounds.merge(box);first=false
		shared_bounds=shared_bounds.grow(1)
		for level:Dictionary in levels:
			if float(level.end)!=0.0:
				record.near_groups.append({"group":group,"level":level,"bounds":shared_bounds,"scale":scale,
					"centre":offset+shared_bounds.get_center()})
				_detail_reach = maxf(_detail_reach,float(level.end)+shared_bounds.get_center().length())
			else:record.far_groups[group.entry.id]={"entry":group.entry,"level":level,"transforms":group.transforms,
				"offset":offset,"centre":offset+shared_bounds.get_center(),"threshold":float(level.begin),"scale":scale}
	var camera := preload("res://world/player_view.gd").camera(self)
	if camera == null or _want_detail(record,camera.global_position): _make_detail(key,record)
	if record.cells.is_empty():
		if is_instance_valid(record.node): record.node.queue_free()
		_detail_cells.erase(key); batches.erase(key)
		var fkey:=_far_key(key);far_index[fkey].erase(key)
		if far_index[fkey].is_empty():far_index.erase(fkey)

func _want_detail(record: Dictionary, eye: Vector3) -> bool:
	for group: Dictionary in record.get("near_groups",[]):
		if eye.distance_to(group.centre) < float(group.level.end)+DETAIL_MARGIN: return true
	return false

func _make_detail(key: Vector2i, record: Dictionary) -> void:
	if is_instance_valid(record.node) or record.get("near_groups",[]).is_empty(): return
	var holder := Node3D.new(); holder.position = Vector3(key.x*SPAN,0,key.y*SPAN)
	for group: Dictionary in record.near_groups:
		_add_level(holder,group.group,group.level,group.bounds,group.scale)
	add_child(holder); record.node = holder; _detail_cells[key] = true

func _refresh_details(eye: Vector3) -> void:
	if _detail_eye.is_finite() and eye.distance_squared_to(_detail_eye)<64.0: return
	_detail_eye = eye
	var wanted := {}
	var centre := Vector2i(floori(eye.x/SPAN),floori(eye.z/SPAN))
	var radius := ceili((_detail_reach+DETAIL_MARGIN)/SPAN)+1
	for z in range(centre.y-radius,centre.y+radius+1):
		for x in range(centre.x-radius,centre.x+radius+1):
			var key := Vector2i(x,z)
			if batches.has(key) and _want_detail(batches[key],eye):
				wanted[key] = true; _make_detail(key,batches[key])
	for key: Vector2i in _detail_cells.keys():
		if wanted.has(key): continue
		if batches.has(key) and is_instance_valid(batches[key].node):
			batches[key].node.queue_free(); batches[key].node = null
		_detail_cells.erase(key)

func _add_level(holder:Node3D,group:Dictionary,level:Dictionary,shared_bounds:AABB,scale:float)->void:
		for part: Array in level.parts:
			var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D;mm.mesh=part[0];mm.instance_count=group.transforms.size()
			mm.buffer=native.pack_transforms(group.transforms,part[1],true) if native!=null else _pack_placed(group.transforms,part[1])
			# Every representation uses the same center for range selection; source
			# leaf/trunk bounds differ and would otherwise open holes at the boundary.
			mm.custom_aabb=shared_bounds
			var instance:=MultiMeshInstance3D.new();instance.multimesh=mm;instance.lod_bias=scale
			# Zero means no range cutoff. Camera/frustum clipping still applies.
			instance.visibility_range_begin=float(level.begin)
			instance.visibility_range_end=float(level.end)
			instance.visibility_range_begin_margin=0
			instance.visibility_range_end_margin=0
			instance.visibility_range_fade_mode=GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			var options: Dictionary = part[2] if part.size() > 2 else {}
			if options.get("shadow_only",false):
				instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
				instance.set_meta("everfree_shadow_proxy",true)
			elif options.get("shadow_off",false):
				instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if options.get("everfree_leaf",false): instance.set_meta("everfree_leaf",true)
			instance.set_meta("painted_tree_id",group.entry.id)
			instance.set_meta("painted_lod",level.get("lod",0))
			holder.add_child(instance)

func _flush_far(fkey: Vector2i) -> void:
	_far_selection_dirty = true
	var origin:=Vector3(fkey.x*FAR_SPAN,0,fkey.y*FAR_SPAN)
	var merged:={}
	for key: Vector2i in far_index.get(fkey,{}):
		for id: String in batches[key].far_groups:
			var group: Dictionary=batches[key].far_groups[id]
			if not merged.has(id):merged[id]={"entry":group.entry,"level":group.level,"scale":1.0,"sources":[],"spans":[],"count":0}
			var target: Dictionary=merged[id]
			target.spans.append({"start":target.count,"count":group.transforms.size(),"centre":group.centre,"threshold":group.threshold,"state":-1,"reach":0.0})
			target.count+=group.transforms.size()
			target.scale=maxf(target.scale,group.scale)
			target.sources.append(group)
	var previous: Dictionary=far.get(fkey,{})
	if is_instance_valid(previous.get("node")):previous.node.queue_free()
	if merged.is_empty():far.erase(fkey);return
	var holder:=Node3D.new();holder.position=origin
	var record:={"node":holder,"species":[]}
	for group: Dictionary in merged.values():
		var impostor: Mesh=IMPOSTORS.mesh(str(group.entry.id)) if impostors else null
		var parts: Array=group.level.parts
		var caches:=[]
		for i in group.sources.size():
			var cache:=_far_cache(group.sources[i],origin,parts,impostor)
			group.spans[i].reach=cache.reach;caches.append(cache)
		var entry:={"spans":group.spans,"meshes":[],"impostor":[],"id":str(group.entry.id)}
		for p in parts.size():
			var mesh: Mesh=parts[p][0] if impostor==null else IMPOSTORS.fading(parts[p][0],str(group.entry.id))
			var built:=_far_instance(mesh,caches,p,group,group.scale,1.0)
			built[0].set_meta("painted_lod",group.level.get("lod",0))
			# A far tile is one 512 m object: casting, it drew every tree in it into each shadow
			# cascade, though the sun's shadows end at 200 m (the Everfree opening, dev 2026-10-01).
			built[0].cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(built[0]);entry.meshes.append(built)
		if impostor!=null:
			# Two triangles per tree past the hand-over; nothing that far casts into the shadow maps.
			var built:=_far_instance(impostor,caches,-1,group,group.scale,group.scale*float(impostor.get_aabb().size.x))
			var instance: MultiMeshInstance3D=built[0]
			instance.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.gi_mode=GeometryInstance3D.GI_MODE_DISABLED
			instance.set_meta("painted_lod",IMPOSTOR_LOD)
			holder.add_child(instance);entry.impostor=built
		record.species.append(entry)
	add_child(holder);far[fkey]=record
	var camera:=preload("res://world/player_view.gd").camera(self)
	if camera!=null:_sync_far(record,camera.global_position,true)

## One batch's far group placed in its far tile: per part the instance buffer and the merged
## bounds of that part's mesh, the impostor's likewise, and the span's reach. Kept on the group,
## so a tile rebuild repacks only batches that changed (_flush_near replaces far_groups).
func _far_cache(group: Dictionary,origin: Vector3,parts: Array,impostor: Mesh)->Dictionary:
	var cache: Dictionary=group.get("far_cache",{})
	if not cache.is_empty() and is_same(cache.parts,parts) and cache.impostor==impostor and cache.origin==origin:return cache
	var shift: Vector3=group.offset-origin
	var placed:=[];var reach:=0.0
	for source: Transform3D in group.transforms:
		var transform:=source;transform.origin+=shift;placed.append(transform)
		reach=maxf(reach,(origin+transform.origin).distance_to(group.centre))
	cache={"parts":parts,"impostor":impostor,"origin":origin,"reach":reach,"chunks":[],"boxes":[]}
	for part: Array in parts:
		var mesh: Mesh=part[0] if impostor==null else IMPOSTORS.fading(part[0],str(group.entry.id))
		if native!=null:
			# placed[i]*part[1] packed and bounded in C++: the floats the loop below builds and packs.
			cache.chunks.append(native.pack_transforms(placed,part[1],true))
			cache.boxes.append(native.merge_bounds(AABB(),true,placed,part[1],mesh.get_aabb(),true)[0]);continue
		var transforms:=[]
		for transform: Transform3D in placed:transforms.append(transform*part[1])
		cache.chunks.append(_pack_placed(transforms,Transform3D.IDENTITY,false));cache.boxes.append(_bounds(transforms,mesh))
	if impostor!=null:
		if native!=null:
			cache.impostor_chunk=native.pack_transforms(placed,Transform3D.IDENTITY,false)
			cache.impostor_box=native.merge_bounds(AABB(),true,placed,Transform3D.IDENTITY,impostor.get_aabb(),false)[0]
		else:cache.impostor_chunk=_pack_placed(placed,Transform3D.IDENTITY,false);cache.impostor_box=_bounds(placed,impostor)
	group.far_cache=cache
	return cache

## One MultiMeshInstance3D for a far tile species (a part index, or -1 for its impostor) from the
## batches' cached buffers, plus those buffers as the per-span chunks _pack uses; `grow` pads
## bounds (impostors turn about Y).
func _far_instance(mesh: Mesh,caches: Array,part: int,group: Dictionary,scale: float,grow: float)->Array:
	var data:=PackedFloat32Array();var chunks:=[]
	var bounds:=AABB();var first:=true
	for cache: Dictionary in caches:
		var chunk: PackedFloat32Array=cache.chunks[part] if part>=0 else cache.impostor_chunk
		data.append_array(chunk);chunks.append(chunk)
		if chunk.is_empty():continue
		var box: AABB=cache.boxes[part] if part>=0 else cache.impostor_box
		bounds=box if first else bounds.merge(box);first=false
	var mm:=MultiMesh.new();mm.transform_format=MultiMesh.TRANSFORM_3D;mm.mesh=mesh;mm.instance_count=int(group.count)
	mm.buffer=data
	mm.custom_aabb=bounds.grow(maxf(1.0,grow))
	var instance:=MultiMeshInstance3D.new();instance.multimesh=mm;instance.lod_bias=scale
	# Compaction reuses indices for unrelated stationary trees; interpolating their
	# transforms invents moving/scaled canopy geometry between physics ticks.
	instance.physics_interpolation_mode=Node.PHYSICS_INTERPOLATION_MODE_OFF
	instance.set_meta("painted_tree_id",group.entry.id)
	return [instance,chunks]

## MultiMesh.buffer layout, the 3x4 matrix row by row (the floats set_instance_transform writes),
## for each transform times `part`; `multiply` off packs them as given (bit-identical, signed zeros too).
static func _pack_placed(transforms: Array,part: Transform3D,multiply:=true)->PackedFloat32Array:
	var data:=PackedFloat32Array();data.resize(transforms.size()*12)
	for i in transforms.size():
		var t: Transform3D=transforms[i]*part if multiply else transforms[i];var b:=t.basis;var o:=t.origin;var k:=i*12
		data[k]=b.x.x;data[k+1]=b.y.x;data[k+2]=b.z.x;data[k+3]=o.x
		data[k+4]=b.x.y;data[k+5]=b.y.y;data[k+6]=b.z.y;data[k+7]=o.y
		data[k+8]=b.x.z;data[k+9]=b.y.z;data[k+10]=b.z.z;data[k+11]=o.z
	return data

## Merged bounds of `mesh` placed by each transform, in order.
static func _bounds(transforms: Array,mesh: Mesh)->AABB:
	var local:=mesh.get_aabb();var bounds:=AABB()
	for i in transforms.size():
		var box: AABB=transforms[i]*local;bounds=box if i==0 else bounds.merge(box)
	return bounds

func _process(_delta: float) -> void:
	if not CPU_PROFILE.enabled:
		_profiled_process(_delta)
		return
	var started := Time.get_ticks_usec()
	_profiled_process(_delta)
	CPU_PROFILE.record("painted_tree_batches", started)

func _profiled_process(_delta: float) -> void:
	var camera:=preload("res://world/player_view.gd").camera(self)
	if camera==null:return
	var eye:=camera.global_position
	_refresh_details(eye)
	var force := IMPOSTORS.from != _impostor_from
	if not force and not _far_selection_dirty and (eye == _far_eye or eye.distance_squared_to(_far_eye) < _far_margin_squared):
		return
	_impostor_from = IMPOSTORS.from
	var margin := INF
	for fkey: Vector2i in far:
		var record: Dictionary = far[fkey]
		_sync_far(record, eye, force)
		# Each tile can retain a different cached eye. Subtract that displacement
		# to get a conservative radius around this eye; keep a rounding allowance.
		margin = minf(margin, maxf(0.0, float(record.margin) - eye.distance_to(record.eye) - 0.01))
	_far_eye = eye
	_far_margin_squared = margin * margin
	_far_selection_dirty = false

## Per span of trees (one 32 m batch): 0 hidden (its detailed batch is drawn), 1 far mesh,
## 2 both (inside the crossfade band, the shaders dither per tree), 3 impostor only.
## Drawn spans are packed at the front of each MultiMesh and the rest cut by visible_instance_count,
## so hidden trees cost nothing on the GPU.
func _sync_far(record: Dictionary,eye: Vector3,force: bool)->void:
	# margin = smallest |distance - boundary| at the last pass: a smaller eye move cannot change a state.
	if not force and record.has("eye") and eye.distance_to(record.eye)<record.margin:return
	record.eye=eye
	var margin:=INF
	for species: Dictionary in record.species:
		var band:=IMPOSTORS.band_for(str(species.get("id","")))
		var has_impostor: bool=not species.impostor.is_empty()
		var changed:=force
		for span: Dictionary in species.spans:
			var d:=eye.distance_to(span.centre)
			var state:=1
			if span.threshold>0.0:margin=minf(margin,absf(d-span.threshold))
			if span.threshold>0.0 and d<span.threshold:state=0
			elif has_impostor:
				margin=minf(margin,minf(absf(d+span.reach-band.x),absf(d-span.reach-band.y)))
				state=1 if d+span.reach<band.x else (3 if d-span.reach>band.y else 2)
			if state!=span.state:span.state=state;changed=true
		if not changed:continue
		for pair: Array in species.meshes:_pack(pair,species.spans,[1,2])
		if has_impostor:_pack(species.impostor,species.spans,[2,3])
	record.margin=margin

func _pack(pair: Array,spans: Array,states: Array)->void:
	var instance: MultiMeshInstance3D=pair[0];var chunks: Array=pair[1];var mm:=instance.multimesh
	var data:=PackedFloat32Array();var used:=0
	for i in spans.size():
		if spans[i].state in states:data.append_array(chunks[i]);used+=int(spans[i].count)
	data.resize(mm.instance_count*12)
	mm.buffer=data;mm.visible_instance_count=used
	instance.visible=used>0
