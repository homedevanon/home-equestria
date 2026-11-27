class_name TerrainSculptor
extends Node
## Time-sliced Terrain3D height authoring. Generated terrain remains the immutable baseline.
signal updated
## Emitted after maps, collision, and navigation see a completed terrain edit.
signal height_changed(bounds: AABB)
const PUBLISHED := "res://world/terrain/sculpt"
const WORKING := "user://world_editor/sculpt"
const REGION_SIZE := 1024
const HISTORY_LIMIT := 256 * 1024 * 1024
const SNAPSHOT_BYTES_PER_REGION := REGION_SIZE * REGION_SIZE * 10
var terrain: Node
var world: Node
var published_dir := PUBLISHED
var working_dir := WORKING
var radius := 24.0
var strength := 2.0
var softness := 0.8
var operation: Variant = "raise" # raise/lower/flatten/smooth; 0..3 accepted by editor UI
var flatten_height := 0.0
var busy := false
var _stroke := {}
var _dabs: Array[Vector2] = []
var _ending := false
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _history_bytes := 0
var _records := {}
var _dirty := {}
## Memory lane 2026-11-21: in play (`bind(world, false)`) each record's unsculpted height copy
## (4 MB per sculpted region; 88 regions, 352 MB with the whole world resident) is read only by the
## published pass of `load_saved`, right after `_ensure` made it. Play drops it after that pass and
## `_baseline` rebuilds it from the region file on disk if a later pass needs it (a record dropped
## by the terrain window is forgotten and re-made from the fresh region anyway). Strokes, undo and
## save read the coverage and the live map, never the baseline. A dropped record's "baseline" is
## null. false keeps every baseline resident as before.
const DROP_PLAY_BASELINES := true
var _play := false

## Perf 0.1.0: _process runs only while dabs or a stroke's ending are queued (dab/finish wake it).
func _ready() -> void: set_process(not _dabs.is_empty() or _ending)

func bind(value: Node, use_working := true) -> void:
	world = value; terrain = value.terrain
	_play = not use_working
	load_saved(use_working)

func begin(invert := false) -> bool:
	if busy or not _stroke.is_empty() or not is_finite(radius) or not is_finite(strength) \
		or not is_finite(softness) or not is_finite(flatten_height): return false
	var op: String = ["raise", "lower", "flatten", "smooth"][operation] if operation is int and operation >= 0 and operation < 4 else str(operation)
	if invert: op = "lower" if op == "raise" else ("raise" if op == "lower" else op)
	if op not in ["raise", "lower", "flatten", "smooth"]: return false
	_stroke = {"before":{},"after":{},"bounds":AABB(),"settings":{"radius":clampf(radius,2,1000),
		"strength":clampf(strength,.1,200),"softness":clampf(softness,0,1),
		"operation":op,"flatten_height":flatten_height}}
	_ending = false; return true

func dab(pos: Vector2) -> void:
	if not _stroke.is_empty() and pos.is_finite() and _dabs.size()<8: _dabs.append(pos); set_process(true)
func finish() -> void: _ending=true; set_process(true)
func settled() -> bool: return not busy and _stroke.is_empty() and _dabs.is_empty()

func _process(_delta: float) -> void:
	if busy:return
	if not _dabs.is_empty(): busy=true; _apply_dab(_dabs.pop_front())
	elif _ending and not _stroke.is_empty():
		for loc in _stroke.before: _stroke.after[loc]=_snapshot(loc)
		if not _stroke.before.is_empty():
			_push_undo(_stroke);_redo.clear()
		_stroke={};_ending=false;updated.emit()
	if _dabs.is_empty() and not _ending: set_process(false)

func _ensure(loc:Vector2i)->Dictionary:
	if _records.has(loc):
		var kept:Dictionary=_records[loc]
		if kept.get("coverage")==null:kept.coverage=_published_coverage(loc,kept.bounds)
		return kept
	var region: Object=terrain.data.get_region(loc)
	if region==null:return {}
	var baseline:Image=region.get_height_map().duplicate()
	var rec={"baseline":baseline,"coverage":Image.create(REGION_SIZE,REGION_SIZE,false,Image.FORMAT_L8),"bounds":Rect2i(),"source":"baseline"}
	_records[loc]=rec;return rec

## A region left the terrain window: its record is stale once the region reloads from disk.
func forget(loc:Vector2i)->void:
	_records.erase(loc);_dirty.erase(loc)

func _snapshot(loc:Vector2i)->Dictionary:
	var region:Object=terrain.data.get_region(loc);var rec:Dictionary=_ensure(loc)
	return {"height":region.get_height_map().duplicate(),"coverage":rec.coverage.duplicate(),"bounds":rec.bounds}

func _apply_dab(pos:Vector2)->void:
	var settings:Dictionary=_stroke.settings;var r:float=settings.radius
	var lo:=Vector2i(floori((pos.x-r)),floori((pos.y-r)))
	var hi:=Vector2i(ceili((pos.x+r)),ceili((pos.y+r)))
	var clock:=Time.get_ticks_usec();var touched:Dictionary={}
	var dab_source:Dictionary={}
	# Undo captures the stroke entrance. Smoothing separately snapshots each dab so a
	# held brush converges while remaining independent of pixel traversal direction.
	for rz in range(floori(float(lo.y-1)/REGION_SIZE),floori(float(hi.y+1)/REGION_SIZE)+1):
		for rx in range(floori(float(lo.x-1)/REGION_SIZE),floori(float(hi.x+1)/REGION_SIZE)+1):
			var loc:=Vector2i(rx,rz)
			if terrain.data.has_region(loc):
				if not _stroke.before.has(loc):_stroke.before[loc]=_snapshot(loc)
				if settings.operation=="smooth":dab_source[loc]=terrain.data.get_region(loc).get_height_map().duplicate()
			if Time.get_ticks_usec()-clock>2000:
				await get_tree().process_frame;clock=Time.get_ticks_usec()
	for y in range(lo.y,hi.y+1):
		for x in range(lo.x,hi.x+1):
			var distance:=Vector2(x,y).distance_to(pos)
			var amount:float=settings.strength*(1.0-smoothstep(r*(1.0-settings.softness),r,distance))
			if amount<=0:continue
			var loc:=Vector2i(floori(float(x)/REGION_SIZE),floori(float(y)/REGION_SIZE));var rec:=_ensure(loc)
			if rec.is_empty():continue
			var pixel:=Vector2i(x,y)-loc*REGION_SIZE;var region:Object=terrain.data.get_region(loc);var map:Image=region.get_height_map()
			var old:=map.get_pixelv(pixel).r;var value:=old
			match settings.operation:
				"raise": value=old+amount
				"lower": value=old-amount
				"flatten": value=move_toward(old,float(settings.flatten_height),amount)
				"smooth":
					var mean:=0.0;var count:=0
					for off in [Vector2i.ZERO,Vector2i.LEFT,Vector2i.RIGHT,Vector2i.UP,Vector2i.DOWN]:
						var sample:=_source_height(dab_source,Vector2i(x,y)+off)
						if is_finite(sample):mean+=sample;count+=1
					if count>0:value=move_toward(old,mean/count,amount)
			map.set_pixelv(pixel,Color(value,0,0));rec.coverage.set_pixelv(pixel,Color.WHITE)
			var cell:=Rect2i(pixel,Vector2i.ONE);rec.bounds=cell if rec.bounds.size==Vector2i.ZERO else rec.bounds.merge(cell)
			rec.source="dirty";region.set_modified(true);region.set_edited(true);_dirty[loc]=true;touched[loc]=true
			if Time.get_ticks_usec()-clock>2000:
				await get_tree().process_frame;clock=Time.get_ticks_usec()
	var dab_bounds:=AABB(Vector3(lo.x,-10000.0,lo.y),Vector3(hi.x-lo.x+1,20000.0,hi.y-lo.y+1))
	_stroke.bounds=_merged_bounds(_stroke.bounds,dab_bounds)
	# A brush edits the Image directly. Restore and load use Terrain3DRegion's
	# set_height_map(), which already recalculates the range of the whole tile.
	for loc in touched:
		var changed_region:Object=terrain.data.get_region(loc)
		if changed_region!=null and changed_region.has_method("calc_height_range"):changed_region.calc_height_range()
	_upload(touched.keys(),dab_bounds);busy=false;updated.emit()

func _stroke_height(point:Vector2i)->float:
	return _source_height(_stroke.before,point)

func _source_height(source:Dictionary,point:Vector2i)->float:
	var loc:=Vector2i(floori(float(point.x)/REGION_SIZE),floori(float(point.y)/REGION_SIZE))
	if not source.has(loc):return NAN
	var pixel:=point-loc*REGION_SIZE
	if pixel.x<0 or pixel.y<0 or pixel.x>=REGION_SIZE or pixel.y>=REGION_SIZE:return NAN
	var entry:Variant=source[loc];var image:Image=entry.height if entry is Dictionary else entry
	return float(image.get_pixelv(pixel).r)

func _upload(locations:Array,change_bounds:=AABB())->void:
	if locations.is_empty():return
	terrain.data.update_maps(0,false,false)
	var collision: Object = terrain.get_collision() if terrain.has_method("get_collision") else null
	if collision != null and collision.has_method("update"): collision.update(true)
	for loc in locations:
		var region:Object=terrain.data.get_region(loc)
		if region!=null:region.set_edited(false)
	# Dynamic Terrain3D collision refreshes through the height-map update. Navigation
	# services must discard height-derived chunks intersecting the edited regions.
	for service in get_tree().get_nodes_in_group("pony_navigation"):
		for loc in locations: service.notify_geometry_changed(AABB(Vector3(loc.x*REGION_SIZE,-10000,loc.y*REGION_SIZE),Vector3(REGION_SIZE,20000,REGION_SIZE)))
	if change_bounds.size!=Vector3.ZERO:height_changed.emit(change_bounds)

func _restore(saved:Dictionary,change_bounds:=AABB())->void:
	for loc in saved:
		var region:Object=terrain.data.get_region(loc);var rec:Dictionary=_ensure(loc)
		region.set_height_map(saved[loc].height.duplicate());region.set_modified(true);region.set_edited(true)
		rec.coverage=saved[loc].coverage.duplicate();rec.bounds=saved[loc].bounds;rec.source="dirty";_dirty[loc]=true
	if change_bounds.size==Vector3.ZERO:change_bounds=_region_bounds(saved.keys())
	_upload(saved.keys(),change_bounds);updated.emit()
func undo()->void:
	if busy:return
	if not _stroke.is_empty():_dabs.clear();_restore(_stroke.before,_stroke.bounds);_stroke={};_ending=false;return
	if _undo.is_empty():return
	var command:Dictionary=_undo.pop_back();_history_bytes-=_command_bytes(command);_redo.append(command);_restore(command.before,command.bounds)
func redo()->void:
	if busy or not _stroke.is_empty() or _redo.is_empty():return
	var command:Dictionary=_redo.pop_back();_push_undo(command);_restore(command.after,command.bounds)

func _merged_bounds(a:AABB,b:AABB)->AABB:
	return b if a.size==Vector3.ZERO else a.merge(b)

func _region_bounds(locations:Array)->AABB:
	var result:=AABB()
	for loc:Vector2i in locations:
		result=_merged_bounds(result,AABB(Vector3(loc.x*REGION_SIZE,-10000,loc.y*REGION_SIZE),Vector3(REGION_SIZE,20000,REGION_SIZE)))
	return result

func _command_bytes(command: Dictionary) -> int:
	return command.get("before", {}).size() * SNAPSHOT_BYTES_PER_REGION

func _push_undo(command: Dictionary) -> void:
	_undo.append(command);_history_bytes+=_command_bytes(command)
	while _undo.size()>1 and _history_bytes>HISTORY_LIMIT:
		_history_bytes-=_command_bytes(_undo.pop_front())

func save(publish:=false)->Error:
	if not settled():return ERR_BUSY
	if publish:
		# Keep the editor overlay current before publication. Otherwise its older
		# coverage wins on the next launch and silently undoes applied height edits.
		var working_error := save(false)
		if working_error != OK: return working_error
	var root_dir:String=published_dir if publish else working_dir
	var index:Dictionary=_read_json(root_dir.path_join("index.json")).get("tiles",{})
	var locations:Array=[]
	for loc:Vector2i in _records:
		if _dirty.has(loc) or (publish and _records[loc].source=="working"):locations.append(loc)
	for loc:Vector2i in locations:
		var rec:Dictionary=_records[loc];var generation:String="%d_%d/%d_%d"%[loc.x,loc.y,Time.get_unix_time_from_system(),Time.get_ticks_usec()]
		var folder:String=root_dir.path_join(generation);DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
		var file:=FileAccess.open(folder.path_join("height.f32"),FileAccess.WRITE)
		if file==null:return FileAccess.get_open_error()
		file.store_buffer(terrain.data.get_region(loc).get_height_map().get_data());file.close()
		var err:Error=rec.coverage.save_png(folder.path_join("coverage.png"));if err!=OK:return err
		err=WorldBiomeField.atomic_json(folder.path_join("meta.json"),{"bounds":[rec.bounds.position.x,rec.bounds.position.y,rec.bounds.size.x,rec.bounds.size.y]});if err!=OK:return err
		index["%d_%d"%[loc.x,loc.y]]=generation
	var result:=WorldBiomeField.atomic_json(root_dir.path_join("index.json"),{"version":1,"tiles":index})
	if result==OK:
		for loc in locations:
			_records[loc].source="published" if publish else "working";_dirty.erase(loc)
	return result

## `only`: restrict to these region locations (the terrain window re-applies per region).
func load_saved(working:=true,only:Array=[])->void:
	var touched:Dictionary={}
	var changed_bounds:=AABB()
	for root_value in [published_dir,working_dir] if working else [published_dir]:
		var root_dir:String=str(root_value)
		var index:Dictionary=_read_json(root_dir.path_join("index.json")).get("tiles",{})
		for key:String in index:
			var xy:=key.split("_")
			if xy.size()!=2 or not xy[0].is_valid_int() or not xy[1].is_valid_int():continue
			var relative:String=str(index[key])
			if relative.is_absolute_path() or ".." in relative or relative.count("/")!=1:continue
			var loc:=Vector2i(int(xy[0]),int(xy[1]))
			if not only.is_empty() and loc not in only:continue
			var rec:=_ensure(loc)
			if rec.is_empty():continue
			var folder:String=root_dir.path_join(relative);var bytes:PackedByteArray=FileAccess.get_file_as_bytes(folder.path_join("height.f32"));var coverage:Image=preload("res://world/resource_image.gd").read(folder.path_join("coverage.png"))
			var meta:Dictionary=_read_json(folder.path_join("meta.json"));var bounds_value:Variant=meta.get("bounds",[])
			if bytes.size()!=REGION_SIZE*REGION_SIZE*4 or coverage==null or coverage.get_width()!=REGION_SIZE or coverage.get_height()!=REGION_SIZE or not bounds_value is Array or bounds_value.size()!=4:continue
			var numeric_bounds:=true
			for component in bounds_value:
				if not component is int and not component is float:numeric_bounds=false;break
			if not numeric_bounds:continue
			coverage.convert(Image.FORMAT_L8)
			var bounds:=Rect2i(int(bounds_value[0]),int(bounds_value[1]),int(bounds_value[2]),int(bounds_value[3]))
			if bounds.position.x<0 or bounds.position.y<0 or bounds.size.x<0 or bounds.size.y<0 or bounds.end.x>REGION_SIZE or bounds.end.y>REGION_SIZE:continue
			# Published data is applied to the immutable generated baseline. Working data
			# then overlays that result, retaining published pixels outside its coverage.
			var map:Image
			if root_dir==working_dir:map=terrain.data.get_region(loc).get_height_map().duplicate()
			elif _play and DROP_PLAY_BASELINES:
				# In place: the region keeps its own Image object, so the terrain plugin holds no
				# stale copy of the unsculpted map once the baseline is dropped.
				map=terrain.data.get_region(loc).get_height_map();map.copy_from(_baseline(loc,rec))
			else:map=_baseline(loc,rec).duplicate()
			var merged_coverage:Image=rec.coverage.duplicate() if root_dir==working_dir else Image.create(REGION_SIZE,REGION_SIZE,false,Image.FORMAT_L8)
			if not preload("res://world/terrain/terrain_overlay.gd").apply(map, bytes, coverage, bounds, merged_coverage): continue
			var region:Object=terrain.data.get_region(loc);region.set_height_map(map);region.set_modified(true);region.set_edited(true);rec.coverage=merged_coverage
			rec.bounds=rec.bounds.merge(bounds) if root_dir==working_dir and rec.bounds.size!=Vector2i.ZERO else bounds
			rec.source="working" if root_dir==working_dir else "published";touched[loc]=true
			var world_bounds:=AABB(Vector3(loc.x*REGION_SIZE+bounds.position.x,-10000,loc.y*REGION_SIZE+bounds.position.y),Vector3(bounds.size.x,20000,bounds.size.y))
			changed_bounds=_merged_bounds(changed_bounds,world_bounds)
	if _play and DROP_PLAY_BASELINES:
		for rec:Dictionary in _records.values():
			rec.baseline=null
			# Coverage (1 MB a region) is read only by editing and saving; _ensure rebuilds it.
			if rec.source=="published":rec.coverage=null
	_upload(touched.keys(),changed_bounds)

## A dropped play record's coverage, rebuilt as the published pass made it.
func _published_coverage(loc:Vector2i,bounds:Rect2i)->Image:
	var merged:=Image.create(REGION_SIZE,REGION_SIZE,false,Image.FORMAT_L8)
	var relative:String=str(_read_json(published_dir.path_join("index.json")).get("tiles",{}).get("%d_%d"%[loc.x,loc.y],""))
	if relative.is_empty():return merged
	var coverage:Image=preload("res://world/resource_image.gd").read(published_dir.path_join(relative).path_join("coverage.png"))
	if coverage==null or coverage.get_width()!=REGION_SIZE or coverage.get_height()!=REGION_SIZE:return merged
	coverage.convert(Image.FORMAT_L8)
	for y in range(bounds.position.y,bounds.end.y):
		for x in range(bounds.position.x,bounds.end.x):
			if coverage.get_pixel(x,y).r>0:merged.set_pixel(x,y,Color.WHITE)
	return merged

## The record's unsculpted heights: kept, or (dropped in play) read again from the region file.
func _baseline(loc:Vector2i,rec:Dictionary)->Image:
	if rec.get("baseline") is Image:return rec.baseline
	var files:Variant=world.get("_region_files") if world!=null else null
	if files is Dictionary and (files as Dictionary).has(loc) and world.has_method("active_data_dir"):
		var path:String=str(world.call("active_data_dir")).path_join(str(files[loc]))
		var region:Resource=ResourceLoader.load(path,"",ResourceLoader.CACHE_MODE_IGNORE)
		if region!=null and region.has_method("get_height_map"):
			var heights:Variant=region.call("get_height_map")
			if heights is Image and (heights as Image).get_width()==REGION_SIZE:
				rec.baseline=(heights as Image).duplicate();return rec.baseline
	push_warning("TerrainSculptor: no region file for %s; the live heights stand in for its baseline" % loc)
	rec.baseline=terrain.data.get_region(loc).get_height_map().duplicate()
	return rec.baseline

static func _read_json(path:String)->Dictionary:
	var value:Variant=JSON.parse_string(FileAccess.get_file_as_string(path)) if FileAccess.file_exists(path) else {}
	return value if value is Dictionary else {}
