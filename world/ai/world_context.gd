extends Node
signal event_recorded(event: Dictionary)
## A world (or an earlier checkpoint of it) was opened: anything remembered from before is stale.
signal reopened(world_id: String)
## Bumped on every open: callbacks and caches from an older epoch are not this world's.
var epoch := 0
## Per-world witnessed events and directional relationships. No LLM writes facts.
## Format of context.json and of the context embedded in save documents. Bump it when the
## shape changes and add MIGRATIONS[old] = func(state)->state that returns version old+1.
const VERSION:=1
const SAVE_FILE:=preload("res://world/save_file.gd")
static var MIGRATIONS:Dictionary={}
const MAX_EVENTS:=4096
const MAX_LORE:=512
const MAX_BYTES:=8*1024*1024
var impressions:Node
## The story journal and prompt memory (world/ai/memory/story_memory.gd); open while a world is.
var story: RefCounted
var player_bonds: Node
var world_id:=""
var path:=""
var error:=""
var state:Dictionary={}
var lore:Dictionary={}
var _seen:Dictionary={}
var _observers:Dictionary={}
var _dirty:=false
var _elapsed:=0.0
var _save_poll_elapsed:=0.0
var _task:=-1
var _write_result:=OK
var _session:=""
var _serial:=0
var _revision:=0
var _saving_revision:=0
var _read_only:=false

static func valid_id(id:String)->bool:
	if id.is_empty() or id.length()>64:return false
	for c in id:
		if not c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-":return false
	return true

func open_world(id:String,base:="user://worlds")->bool:
	if not valid_id(id):error="Invalid world ID";return false
	if _task>=0 or _dirty:error="Close/save the current world first";return false
	world_id=id;path=base.path_join(id).path_join("context.json")
	state={"version":VERSION,"world_id":id,"events":[],"relationships":{},"lore":{},"removed_lore":[],"revision":0}
	_read_only=false;error=""
	var loaded:=SAVE_FILE.read_checked(path,MAX_BYTES,func(value:Variant)->String:
		if is_newer(value):return SAVE_FILE.NEWER
		return "" if _valid_state(migrate_state(value),id) else "invalid context")
	# A newer build's context is left untouched and not overwritten; a damaged one falls back
	# to context.json.previous, else it is kept aside and this world starts a fresh memory
	# (the save slots carry their own copy of the context).
	if loaded.status=="newer":return _load_failed(loaded.message)
	if loaded.status in ["recovered","lost"]:error=loaded.message;push_warning("[context] "+error)
	if loaded.doc!=null:state=migrate_state(loaded.doc)
	_revision=int(state.get("revision",0));_seen.clear();_observers.clear()
	_session=Crypto.new().generate_random_bytes(12).hex_encode();_serial=0
	for event:Dictionary in state.events:_index(event)
	lore.clear()
	var seeds:Variant=JSON.parse_string(FileAccess.get_file_as_string("res://world/ai/context_seeds.json"))
	if seeds is Dictionary:
		for entry:Dictionary in seeds.get("lore",[]):
			if _valid_lore(entry) and entry.id not in state.removed_lore:lore[entry.id]=entry
		for row:Dictionary in seeds.get("relationships",[]):
			if not state.relationships.get(row.from,{}).has(row.to):
				set_relationship(row.from,row.to,row.familiarity,row.trust,row.preference)
	for key in state.lore:lore[key]=state.lore[key]
	if not is_instance_valid(impressions):
		impressions=preload("res://world/ai/impressions/pony_impressions.gd").new();add_child(impressions)
	impressions.bind(self)
	if not is_instance_valid(player_bonds):
		player_bonds = preload("res://world/relationships/player_bonds.gd").new()
		player_bonds.name = "PlayerBonds"
		add_child(player_bonds)
	player_bonds.bind(self)
	# Debug seed only at world creation. Continue, checkpoint restoration and
	# damaged-world recovery must never overwrite earned relationship changes.
	if loaded.status=="missing" and "--dashie" in preload("res://world/dev_tools.gd").user_args():
		impressions.core.set_score("rainbow_dash","romance",100)
		state.player_impressions={"core":impressions.core.get_save_state(),
			"notes":impressions.notes.duplicate(true),"sessions":impressions.sessions.duplicate(true),
			"applied":impressions.applied.duplicate(true)}
		_changed()
	if story == null: story = preload("res://world/ai/memory/story_memory.gd").new()
	story.context = self
	story.clock = _story_clock
	if not story.open(base.path_join(id).path_join("story.db")): push_warning("[context] story journal unavailable: " + str(story.store.error))
	if not event_recorded.is_connected(story.mirror): event_recorded.connect(story.mirror)
	epoch += 1
	reopened.emit(world_id)
	return true

func _story_clock() -> Dictionary:
	var clock: Node = get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	if clock == null: return {"day": 0, "minute": 0}
	return {"day": int(clock.day), "minute": int(float(clock.hours) * 60.0)}

func _load_failed(message:String)->bool:
	error=message;_read_only=true;return false

func restore_checkpoint(value:Dictionary)->bool:
	if _read_only or not _valid_state(value,world_id):return false
	if _task>=0:WorkerThreadPool.wait_for_task_completion(_task);_task=-1
	state=value.duplicate(true);_seen.clear();_observers.clear()
	for event:Dictionary in state.events:_index(event)
	_revision=int(state.get("revision",0))+1;state.revision=_revision;_dirty=true
	if flush()!=OK:return false
	# Reuse normal seed/correction/Impressions restoration after the atomic write.
	return open_world(world_id,path.get_base_dir().get_base_dir())

static func is_newer(value:Variant)->bool:
	return value is Dictionary and (value.get("version") is int or value.get("version") is float) and float(value.version)>VERSION

## Upgrade an older state one version at a time; anything else is returned unchanged
## (and then fails _valid_state).
static func migrate_state(value:Variant)->Variant:
	if not value is Dictionary:return value
	var result:Dictionary=value
	while (result.get("version") is int or result.get("version") is float) and int(result.version)<VERSION and MIGRATIONS.has(int(result.version)):
		var from:=int(result.version)
		result=MIGRATIONS[from].call(result.duplicate(true))
		if not result.get("version") is int and not result.get("version") is float or int(result.version)<=from:break
	return result

static func _valid_state(value:Variant,id:String)->bool:
	if not value is Dictionary or value.get("version")!=VERSION or value.get("world_id")!=id:return false
	if not value.get("events") is Array or value.events.size()>MAX_EVENTS:return false
	if not value.get("relationships") is Dictionary or not value.get("lore") is Dictionary:return false
	if not value.get("removed_lore") is Array or value.lore.size()>MAX_LORE:return false
	if value.has("player_impressions") and not preload("res://world/ai/impressions/pony_impressions.gd").valid_save(value.player_impressions):return false
	if value.has("player_bonds") and not preload("res://world/relationships/player_bonds.gd").valid_save(value.player_bonds):return false
	if value.has("player_form") and not preload("res://world/life/player_form.gd").valid(value.player_form):return false
	# Mod save sections (world/modding/mods.gd state()): one dictionary per mod id.
	if value.has("mods") and (not value.mods is Dictionary or not value.mods.values().all(func(v:Variant)->bool:return v is Dictionary)):return false
	for e in value.events:
		if not e is Dictionary or not e.get("id") is String or not e.get("text") is String or e.text.length()>3000:return false
		if not e.get("witnesses") is Array or not e.get("subjects") is Array or not e.get("kind") is String:return false
		if not e.get("place") is String or not e.get("provenance") is String:return false
		if not (e.get("time") is float or e.get("time") is int) or not is_finite(float(e.time)):return false
		if e.witnesses.size()>128 or e.subjects.size()>128:return false
		for subject in e.subjects:
			if not subject is String or not valid_id(subject):return false
		for who in e.witnesses:
			if not who is String or not valid_id(who):return false
	for observer in value.relationships:
		if not valid_id(observer) or not value.relationships[observer] is Dictionary:return false
		for other in value.relationships[observer]:
			if not valid_id(other):return false
			var row:Variant=value.relationships[observer][other]
			if not row is Dictionary:return false
			for field in ["familiarity","trust","preference","last_shared"]:
				if not row.get(field) is float and not row.get(field) is int:return false
				if not is_finite(float(row[field])):return false
	for entry in value.lore.values():
		if not entry is Dictionary or not _valid_lore(entry):return false
	return true

func _index(event:Dictionary)->void:
	_seen[event.id]=true
	for who:String in event.witnesses:
		if not _observers.has(who):_observers[who]=[]
		_observers[who].append(event)

func _changed()->void:
	if _read_only:return
	_revision+=1;state.revision=_revision;_dirty=true

func record(kind:String,text:String,witnesses:Array,subjects:Array=[],event_id:="",place:="")->String:
	if _read_only or world_id.is_empty() or text.strip_edges().is_empty():return ""
	var who:Array=[]
	for id in witnesses:
		if id is String and valid_id(id) and id not in who:who.append(id)
	if who.is_empty():return ""
	if who.size()>128 or subjects.size()>128:return ""
	for subject in subjects:
		if not subject is String or not valid_id(subject):return ""
	if event_id.is_empty():_serial+=1;event_id=_session+"-"+str(_serial)
	if _seen.has(event_id):return ""
	var event:={"id":event_id,"kind":kind.left(40),"text":text.left(3000),"witnesses":who,
		"subjects":subjects.duplicate(),"place":place.left(80),"time":Time.get_unix_time_from_system(),"provenance":"observed"}
	state.events.append(event);_index(event)
	if state.events.size()>MAX_EVENTS:
		var old:Dictionary=state.events.pop_front();_seen.erase(old.id)
		for id in old.witnesses:_observers[id].erase(old)
	_changed()
	event_recorded.emit(event.duplicate(true))
	return event_id

func events_for(observer:String,limit:=32)->Array:
	var events:Array=_observers.get(observer,[])
	return events.slice(maxi(0,events.size()-clampi(limit,0,128))).duplicate(true)

func correct_event(id:String,text:String)->bool:
	if _read_only or text.is_empty():return false
	for i in state.events.size():
		var event:Dictionary=state.events[i]
		if event.id==id:
			# Replaced, never edited in place: a save in flight may still be reading the old record.
			var fixed:=event.duplicate(true);fixed.text=text.left(3000);fixed.provenance="human correction"
			state.events[i]=fixed
			for who in event.witnesses:
				var seen:Array=_observers.get(who,[])
				var at:=seen.find(event)
				if at>=0:seen[at]=fixed
			_changed();return true
	return false

func forget_event(id:String)->bool:
	if _read_only:return false
	for i in state.events.size():
		var e:Dictionary=state.events[i]
		if e.id!=id:continue
		for who in e.witnesses:_observers[who].erase(e)
		state.events.remove_at(i);_seen.erase(id);_changed();return true
	return false

func relationship(observer:String,other:String)->Dictionary:
	return state.get("relationships",{}).get(observer,{}).get(other,{"familiarity":0.,"trust":0.,"preference":0.,"last_shared":0.}).duplicate(true)

func set_relationship(observer:String,other:String,familiarity:float,trust:float,preference:float)->bool:
	if _read_only or not valid_id(observer) or not valid_id(other) or observer==other:return false
	if not is_finite(familiarity) or not is_finite(trust) or not is_finite(preference):return false
	if not state.relationships.has(observer):state.relationships[observer]={}
	var row:=relationship(observer,other)
	row.familiarity=clampf(familiarity,0,1);row.trust=clampf(trust,-1,1);row.preference=clampf(preference,-1,1)
	state.relationships[observer][other]=row;_changed();return true

func shared_event(kind:String,members:Array,event_id:String,text:String)->bool:
	if record(kind,text,members,members,event_id)=="":return false
	var now := _active_now()
	for who:String in members:
		for other:String in members:
			if who==other:continue
			var r:=relationship(who,other)
			# Repeated lines/contact cannot farm affection; familiarity is not trust.
			if r.get("shared_clock", "") == "active" and now-float(r.last_shared)<120:continue
			set_relationship(who,other,r.familiarity+.012,r.trust,r.preference+(.005 if kind=="shared_outing" else 0.))
			state.relationships[who][other].last_shared=now
			state.relationships[who][other].shared_clock="active"
	return true

func _active_now() -> float:
	var clock: Node = get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	return float(clock.active_seconds) if clock != null else Time.get_ticks_msec() / 1000.0

func companion_weight(observer:String,other:String,distance:float,mood:=0.0)->float:
	var r:=relationship(observer,other)
	var affinity:=clampf(1.+r.preference*1.3+r.trust*.4+r.familiarity*.5+mood*.2,.15,3.)
	var recent: bool = r.get("shared_clock", "") == "active" and _active_now()-float(r.last_shared)<300
	return affinity*(.65 if recent else 1.)/(1.+maxf(distance,0)*.08)

static func _valid_lore(e:Dictionary)->bool:
	if not e.get("id") is String or not valid_id(e.id) or not e.get("text") is String or e.text.length()>4000:return false
	for key in ["triggers","viewers"]:
		if not e.get(key) is Array:return false
		for item in e[key]:
			if not item is String or item.length()>80:return false
	var priority:Variant=e.get("priority",0)
	return e.get("scope","") in ["canon","authored","memory"] and (priority is float or priority is int) and is_finite(float(priority))

func set_lore(entry:Dictionary)->bool:
	# JSON numbers may be either integer or float when authored in code.
	var copy:Dictionary=entry.duplicate(true);copy.priority=float(copy.get("priority",0))
	if _read_only or not _valid_lore(copy) or (not lore.has(copy.id) and lore.size()>=MAX_LORE):return false
	state.lore[copy.id]=copy;lore[copy.id]=copy;state.removed_lore.erase(copy.id);_changed();return true

func remove_lore(id:String)->bool:
	if _read_only or not lore.has(id):return false
	lore.erase(id);state.lore.erase(id)
	if id not in state.removed_lore:state.removed_lore.append(id)
	_changed();return true

static func _matches(text:String,trigger:String)->bool:
	var lower:=text.to_lower();var needle:=trigger.to_lower().strip_edges()
	if needle.is_empty():return false
	var start:=0
	while true:
		var at:=lower.find(needle,start)
		if at<0:return false
		var end:=at+needle.length()
		if (at==0 or not _word(lower[at-1])) and (end==lower.length() or not _word(lower[end])):return true
		start=at+1
	return false

static func _word(c:String)->bool:return c in "abcdefghijklmnopqrstuvwxyz0123456789_"

## Lorebook entries only (keyword triggers, priority order, character budget): the story
## journal supplies events and feelings in its own plain sections.
func lore_for(observer:String,topics:String,visible_ids:Array=[],place:="",budget:=1200,audience:Array=[])->String:
	var query:=topics+" "+" ".join(visible_ids)+" "+place+" "+observer
	var ranked:Array=[]
	for e:Dictionary in lore.values():
		if not e.viewers.is_empty() and observer not in e.viewers:continue
		if not audience.is_empty() and not e.viewers.is_empty() and not audience.all(func(id):return id in e.viewers):continue
		if e.triggers.any(func(t):return _matches(query,t)):ranked.append({"score":float(e.priority),"id":e.id,"line":"- "+str(e.text)})
	ranked.sort_custom(func(a,b):return a.score>b.score if a.score!=b.score else a.id<b.id)
	var lines:PackedStringArray=[];var used:=0
	for row:Dictionary in ranked:
		if used+row.line.length()+1>budget:continue
		lines.append(row.line);used+=row.line.length()+1
	return "" if lines.is_empty() else "WORLD FACTS THAT APPLY\n"+"\n".join(lines)

func context_for(observer:String,topics:String,visible_ids:Array=[],place:="",budget:=3200,audience:Array=[])->String:
	var query:=topics+" "+" ".join(visible_ids)+" "+place+" "+observer
	var ranked:Array=[]
	for e:Dictionary in lore.values():
		if not e.viewers.is_empty() and observer not in e.viewers:continue
		if not audience.is_empty() and not e.viewers.is_empty() and not audience.all(func(id):return id in e.viewers):continue
		if e.triggers.any(func(t):return _matches(query,t)):
			ranked.append({"score":float(e.priority),"id":e.id,"line":"[%s; %s] %s"%[e.scope,e.get("provenance","authored"),e.text]})
	var recent:=events_for(observer,32)
	for i in recent.size():
		var e:Dictionary=recent[i]
		if not audience.is_empty() and not audience.all(func(id):return id in e.witnesses):continue
		var relevant:bool=e.subjects.any(func(id):return id in visible_ids) or (place!="" and e.place==place)
		var attribution:="; speaker "+str(e.subjects[0])+" to "+str(e.subjects[1]) if e.kind=="heard_speech" and e.subjects.size()>=2 else ""
		ranked.append({"score":10.+(20. if relevant else 0.)+i*.1,"id":e.id,"line":"[Past %s%s; %s; %s] %s"%[e.kind,attribution,e.provenance,e.id,e.text]})
	ranked.sort_custom(func(a,b):return a.score>b.score if a.score!=b.score else a.id<b.id)
	var lines:PackedStringArray=[];var used:=0
	for row:Dictionary in ranked:
		if used+row.line.length()+1>clampi(budget,0,12000):continue
		lines.append(row.line);used+=row.line.length()+1
	for other:String in ([] if not audience.is_empty() else visible_ids.slice(0,6)):
		if other==observer:continue
		var r:=relationship(observer,other)
		var line:="[Your relationship toward %s only] familiarity %.2f, trust %.2f, fondness for company %.2f. You cannot read their thoughts."%[other,r.familiarity,r.trust,r.preference]
		if used+line.length()+1<=budget:lines.append(line);used+=line.length()+1
	return "\n".join(lines)

func _process(delta:float)->void:
	_elapsed+=delta
	_save_poll_elapsed+=delta
	if _save_poll_elapsed<1.:return
	_save_poll_elapsed=fmod(_save_poll_elapsed,1.0)
	if _task>=0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task);_task=-1
		if _write_result!=OK:error="Context save failed: "+str(_write_result);_dirty=true
	if _elapsed<10. or not _dirty or _task>=0 or _read_only:return
	_elapsed=0.;_dirty=false;_saving_revision=_revision
	var snapshot:=snapshot_state();var destination:=path
	_task=WorkerThreadPool.add_task(func():_write_result=_write(destination,snapshot))

## state.duplicate(true), sharing the event records: those are only appended or dropped (a
## correction replaces the record), so the save worker may read them while play goes on.
## Deep-copying 4096 events stalled a frame at every save.
func snapshot_state()->Dictionary:
	var result:={}
	for key in state:
		var item:Variant=state[key]
		if key=="events" and item is Array:result[key]=item.duplicate()
		elif item is Dictionary or item is Array:result[key]=item.duplicate(true)
		else:result[key]=item
	return result

static func _write(destination:String,snapshot:Dictionary)->Error:
	return SAVE_FILE.write(destination,snapshot,MAX_BYTES)

## The next save poll (within a second) writes in the background instead of waiting out the ten
## second interval: for changes another file already saved its side of (letters leaving the briefcase).
func save_soon()->void:
	_elapsed=maxf(_elapsed,10.)

func flush()->Error:
	if _task>=0:
		WorkerThreadPool.wait_for_task_completion(_task);_task=-1
		# A direct flush can consume the worker before _process sees its error. Retain
		# the dirty snapshot so an I/O failure can be retried without another game event.
		if _write_result!=OK:_dirty=true
	if _read_only:return ERR_FILE_CORRUPT
	if not _dirty and _saving_revision==_revision:return _write_result
	if path.is_empty():return OK
	_write_result=_write(path,state);_dirty=_write_result!=OK;_saving_revision=_revision
	return _write_result

func _exit_tree()->void:
	if not path.is_empty():flush()
	if story != null: story.store.close()
