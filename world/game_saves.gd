extends Node
## Three manual slots, any number of named manual saves (save_new) and an independent rolling
## autosave, all single-file snapshots.
## Format versions, migrations, backups and the autosave on quit: docs/ALPHA_SAVES.md.
signal changed
const CONTEXT=preload("res://world/ai/world_context.gd")
const INVENTORY=preload("res://world/inventory/inventory_store.gd")
const CLOTHES=preload("res://world/customization/clothing_profile.gd")
const LIFE=preload("res://world/life/living_world.gd")
const CLOCK=preload("res://autoload/time_of_day.gd")
const RAIL = preload("res://world/railway/rail_service.gd")
const POPULATION=preload("res://world/population/pony_population_config.gd")
const LIFE_CHECKPOINT=preload("res://world/life/life_checkpoint.gd")
const SAVE_FILE=preload("res://world/save_file.gd")
const FOOD_WORLD=preload("res://world/food/food_world.gd")
const SHOP_WORLD=preload("res://world/shop/shop_world.gd")
const APPLE_BUCKING=preload("res://world/minigames/apple_bucking/apple_bucking.gd")
const LEDGER=preload("res://world/mechanics/ledger.gd")
const LEGACY=preload("res://world/mechanics/legacy.gd")
const JOBS=preload("res://world/mechanics/jobs/jobs.gd")
## Save document format. Bump it whenever the document shape changes and add
## MIGRATIONS[old] = func(doc) -> doc that returns format old+1. Formats 1 and 2 predate
## the `format` key; their `version` field is their format.
const BOOKS = preload("res://world/books/book_library.gd")
## Easel work-in-progress pointers and painting labels (additive "paintings" key, no format bump).
const REGISTRY = preload("res://world/painting/painting_registry.gd")
## What menus show about each checkpoint (sidecar headers) and its screenshot.
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const PREVIEW := preload("res://world/saves/save_preview.gd")
## Names, tags and stars travel with a checkpoint when it is archived or deleted (world/saves/save_shelf.gd).
const SHELF := preload("res://world/saves/save_shelf.gd")
const COTTAGE_RESUME := preload("res://world/buildings/fluttershy/cottage_checkpoint_resume.gd")
## Scenario mods (world/modding/scenario.gd, M-MOD-10): checkpoints carry their world's scenario
## stamp (additive "scenario": {id, name}, no format bump; also in the menu header), and a scenario
## save loads only while that scenario mod runs, a vanilla one only while none does. Title
## Continue and Load game (stage), in-game Load and F8 (load_save), another world's save
## (load_world_save) and the resume itself (take_resume) all ask scenario_problem().
const SCENARIO := preload("res://world/modding/scenario.gd")
const FORMAT:=5
static var MIGRATIONS:Dictionary={1:_from_1,2:_from_2,3:_from_3,4:_from_4}
const MAX_BYTES:=CONTEXT.MAX_BYTES*2
## Longest the quit may wait for the final autosave to reach the disk.
const QUIT_BUDGET_MS:=2000
static var pending:Dictionary={}
## Set by the home screen before entering: which world to open, and whether to skip the
## autosave resume (New Game). Consumed once by game.gd / take_resume().
static var requested_world:=""
static var start_fresh:=false
static var fresh_start_day := 0
## Why the last stage() refused its save, in words for the menus ("" for damaged or newer files,
## which keep their own messages): today only the scenario rule ("Needs the <Name> mod").
static var last_problem := ""
const WORLDS_ROOT:="user://worlds"

## Every checkpoint on disk across worlds (slots, autosave, archives), newest first:
## {path, world_id, label, saved_at, hours, day, kind, place, form, preview, ...}. Header read
## (world/saves/save_catalogue.gd); full validation happens when one is chosen.
static func catalogue()->Array[Dictionary]:
	return CATALOGUE.catalogue(WORLDS_ROOT)

## Home-screen pick: validate the file for its own world and stage it for the game.
static func stage(entry:Dictionary)->bool:
	last_problem=""
	var opened:=open_save(str(entry.path),str(entry.world_id))
	if opened.doc.is_empty():return false
	var problem:=scenario_problem(opened.doc)
	if problem!="":last_problem=problem;push_warning("[saves] %s not loaded: %s"%[str(entry.path).get_file(),problem]);return false
	# The same journal copy an in-game Load uses (load_save), so both paths restore alike.
	opened.doc["story_source"]=str(entry.path).get_basename()+".story.db"
	pending=opened.doc;requested_world=str(entry.world_id);start_fresh=false
	return true

## "" when a parsed checkpoint may load this launch, else the plain reason (world/modding/scenario.gd
## compatible()): "Needs the <Name> mod" or "Turn off the <Name> mod to load this". Saves without a
## stamp (all older ones) are vanilla.
static func scenario_problem(doc:Dictionary)->String:
	return str(SCENARIO.check_doc(doc).reason)

static func stage_new_game(day: int = 0)->String:
	var stamp:=Time.get_datetime_string_from_system(false,true).replace(":","").replace(" ","-")
	# Separate even back-to-back starts; existing context-only worlds are never fresh.
	requested_world="world-"+stamp+"-"+Crypto.new().generate_random_bytes(8).hex_encode()
	start_fresh=true;fresh_start_day=maxi(0, day);pending={}
	return requested_world
var host:Node
var directory:=""
var message:=""
var busy:=false
var restoring:=false
var ready_to_save:=false
var _timer:=0.0
var _task:=-1
var _result:=OK
var _invalid:=false
## The check that refused the last write (invalid_reason), printed with the failure.
var _invalid_reason:=""
## Set by take_resume when the world's resume belongs to another scenario (or to vanilla while a
## scenario runs): game.gd then goes back to the title instead of entering. The save is untouched.
var scenario_block:=""
var _story_error:=""
var _saved_label:=""
var _resume_source:=""
## M-SAV-02 (thread 43688556): this session resumed an older checkpoint than the world's newest
## autosave/quit save. Before the first autosave write replaces it (and, a minute later, its
## .previous), that newer autosave moves to the archive, still listed and loadable.
var _keep_autosave:=false
var _loaded_at:=0.0
## Successful unmarked restore only; scenic title poses must not consume this request.
var pending_cottage_feet := Vector3.INF
var _quit_saved:=false
var _quit_thread:Thread
## The frame under an open menu (remember_view), used by saves made while it covers the view.
var _menu_view:Image
var _view_holders:Array[int]=[]
## The asynchronous screenshot the running save task waits for (cancelled before blocking on it).
var _preview_pending=null

func setup(game:Node,folder:String)->void:
	host=game;directory=folder
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(directory.path_join("archive")))
	for i in 3:
		var path:=slot_path(i)
		if not FileAccess.file_exists(path) and not FileAccess.file_exists(path+".previous"):
			SAVE_FILE.write(path,{"format":FORMAT,"version":1,"empty":true})

func slot_path(index:int)->String:
	return directory.path_join("slot_%d.json"%(index+1)) if index>=0 and index<3 else ""

static func vector(value:Vector3)->Array:return [value.x,value.y,value.z]
static func unvector(value:Array)->Vector3:return Vector3(value[0],value[1],value[2])
static func valid_vector(value:Variant)->bool:
	return value is Array and value.size()==3 and value.all(func(n):return (n is int or n is float) and is_finite(float(n)) and absf(n)<100000.)

static func _number(value:Variant)->float:
	return float(value) if (value is int or value is float) and is_finite(float(value)) else 0.0

## The format a parsed document claims: `format`, else the legacy `version`; 0 if neither.
static func format_of(doc:Dictionary)->int:
	var value:Variant=doc.get("format",doc.get("version"))
	return int(value) if (value is int or value is float) and is_finite(float(value)) and float(value)>=1 else 0

## Upgrade a document to FORMAT one step at a time. {} when a step is missing or broken.
static func migrate(doc:Dictionary)->Dictionary:
	var result:=doc.duplicate(true)
	var from:=format_of(result)
	while from<FORMAT:
		if not MIGRATIONS.has(from):return {}
		result=MIGRATIONS[from].call(result)
		var next:=format_of(result)
		if next<=from:return {}
		from=next
	return result if from==FORMAT else {}

## Format 1: the clock was only day + hours; no living world, roster or railway yet.
static func _from_1(doc:Dictionary)->Dictionary:
	var day:=floorf(maxf(_number(doc.get("day")),0));var hours:=clampf(_number(doc.get("hours",8)),0,23.99)
	doc.clock={"version":1,"day":day,"hours":hours,"day_length_minutes":CLOCK.DEFAULT_DAY_LENGTH_MINUTES,"active_seconds":0.0,"sunset_clock_rate":.4}
	doc.life={};doc.population={};doc.version=2;doc.format=2
	return doc

## Format 3 only made the format explicit; `version` stays 2 so older builds still read it.
static func _from_2(doc:Dictionary)->Dictionary:
	doc.format=3
	return doc

## Food depletion and seasonal harvest receipts travel with the same inventory.
static func _from_3(doc:Dictionary)->Dictionary:
	if not doc.has("food"): doc.food = {}
	if not doc.has("harvest"): doc.harvest = {"version":1,"ledger":{"version":1,"trees":{}},"drops":{}}
	doc.format=4
	return doc

## Legacy global book progress has no provable owner. Preserve it on disk, never
## inject it into another world; newer checkpoints carry their own shelf state.
static func _from_4(doc: Dictionary) -> Dictionary:
	doc.books = {}; doc.format = 5
	return doc

## Wardrobe migration (dev 2026-10-14): Anon's human clothes are bought at Rarity's Boutique and
## kept in his wardrobe, not carried. A checkpoint without clothes.owned is from before: its
## bought outfits and wing sandals leave the briefcase (hands and ground too) for clothes.owned,
## and every colour and pattern he was wearing stays his (world/customization/clothing_profile.gd
## adopt_items, legacy_owned). Runs once per document (the key then exists). FORMAT stays 5:
## the key is additive, and world/ui/title_screen.gd keeps its own copy of the number.
static func _adopt_bought_clothes(doc: Dictionary) -> void:
	if not CLOTHES.valid(doc.get("clothes")) or doc.clothes.has("owned"): return
	if INVENTORY.valid_document(doc.get("inventory")): CLOTHES.adopt_items(doc.clothes, doc.inventory, true)
	else: doc.clothes["owned"] = CLOTHES.legacy_owned(doc.clothes)

## Parsed JSON -> {verdict, doc, notes}. verdict "" = usable (doc migrated, optional parts
## that no longer validate dropped and listed in notes), SAVE_FILE.NEWER = made by a newer
## build, anything else = why it cannot be used. An empty slot is usable with doc {}.
static func prepare(raw:Variant,world_id:String)->Dictionary:
	if not raw is Dictionary:return {"verdict":"not a save document","doc":{},"notes":[]}
	if raw.get("empty",false):return {"verdict":"","doc":{},"notes":[]}
	var format:=format_of(raw)
	if format>FORMAT:return {"verdict":SAVE_FILE.NEWER,"doc":{},"notes":[]}
	var doc:=migrate(raw)
	if doc.is_empty():return {"verdict":"unknown save format %d"%format,"doc":{},"notes":[]}
	var notes:=_tolerate(doc,world_id)
	if not valid(doc,world_id):return {"verdict":"invalid save","doc":{},"notes":[]}
	return {"verdict":"","doc":doc,"notes":notes}

## Defaults for keys an older or hand-edited document may lack, and drop optional parts an
## update made invalid (living world, train, roster, resident rows) rather than the save.
static func _tolerate(doc:Dictionary,world_id:String)->Array[String]:
	var notes:Array[String]=[]
	_adopt_bought_clothes(doc)
	for key in ["yaw","saved_at"]:
		if not doc.get(key) is int and not doc.get(key) is float or not is_finite(float(doc[key])):doc[key]=0.0
	if CLOCK.valid_state(doc.get("clock")):
		for key in ["hours","day"]:
			if not doc.get(key) is int and not doc.get(key) is float:doc[key]=doc.clock[key]
	var rows:Variant=doc.get("residents")
	doc.residents={}
	if rows is Dictionary:
		for id in rows:
			var row:Variant=rows[id]
			if doc.residents.size()<256 and id is String and CONTEXT.valid_id(id) and row is Dictionary and row.get("region") is String and valid_vector(row.get("position")) and valid_vector(row.get("rotation")):
				doc.residents[id]=row
		if doc.residents.size()<rows.size():notes.append("Some pony positions were reset.")
	if not doc.get("population") is Dictionary:doc.population={}
	if not doc.population.is_empty():
		if doc.population.get("assignments") is Dictionary:
			var known:=POPULATION.catalogue();var regions:={}
			for region:Dictionary in POPULATION.regions():regions[str(region.id)]=true
			var kept:={}
			for id in doc.population.assignments:
				if known.has(id) and regions.has(str(doc.population.assignments[id])):kept[id]=doc.population.assignments[id]
			doc.population.assignments=kept
		if not POPULATION.new().apply_data(doc.population):doc.population={};notes.append("The resident list was reset.")
	if doc.has("railway") and not RAIL.valid(doc.railway):doc.erase("railway");notes.append("The train was reset.")
	if not doc.get("life") is Dictionary:doc.life={}
	if not doc.life.is_empty():
		doc.life=LIFE_CHECKPOINT.migrate(doc.life)
		if not LIFE.valid(doc.life,world_id) or not _rail_matches(doc):doc.life={};notes.append("Pony plans were reset.")
	doc.context=CONTEXT.migrate_state(doc.get("context"))
	return notes

## Every resident riding the train is aboard the saved train. Needs a valid doc.life.
static func _rail_matches(doc:Dictionary)->bool:
	for id in doc.life.residents:
		var journey:Dictionary=doc.life.residents[id].journey
		if journey.get("aboard",false):
			if not doc.has("railway") or id not in doc.railway.travellers:return false
			if doc.life.routes[journey.route].get("service")!=doc.railway.route:return false
	return true

static func valid(doc:Variant,world_id:String)->bool:
	return invalid_reason(doc,world_id)==""

## Why valid() refuses `doc` ("" when it is valid): the first failed check, logged with "State could
## not be saved" so a player report names the part that broke (M-SAV-04). Same checks, same order.
static func invalid_reason(doc:Variant,world_id:String)->String:
	if not doc is Dictionary or format_of(doc)!=FORMAT or doc.get("world_id")!=world_id:return "header"
	if not CLOCK.valid_state(doc.get("clock")):return "clock"
	if not doc.get("life") is Dictionary or not doc.get("population") is Dictionary:return "life/population shape"
	if not doc.life.is_empty() and not LIFE.valid(doc.life,world_id):return "life"
	if not doc.population.is_empty() and not POPULATION.new().apply_data(doc.population):return "population roster"
	if doc.has("railway") and not RAIL.valid(doc.railway):return "railway"
	if not doc.life.is_empty() and not _rail_matches(doc):return "rail journeys"
	if not valid_vector(doc.get("position")):return "player position"
	if not CONTEXT._valid_state(doc.get("context"),world_id):return "world context"
	if not INVENTORY.valid_document(doc.get("inventory")):return "inventory"
	if not CLOTHES.valid(doc.get("clothes")):return "clothes"
	if not BOOKS.valid_state(doc.get("books", {})): return "books"
	if not REGISTRY.valid_state(doc.get("paintings", {})): return "paintings"
	if doc.has("wing_flight") and not preload("res://player/wing_flight.gd").valid(doc.wing_flight): return "wing flight"
	# Never silently reset spent stock or paid harvests: that would duplicate items/rewards.
	if doc.has("food") and not FOOD_WORLD.valid_snapshot(doc.food):return "food"
	if doc.has("shops") and not SHOP_WORLD.valid_snapshot(doc.shops):return "shops"
	if doc.has("harvest") and not APPLE_BUCKING.valid_snapshot(doc.harvest):return "harvest"
	for key in ["yaw","hours","day","saved_at"]:
		if not doc.get(key) is int and not doc.get(key) is float:return key
		if not is_finite(float(doc[key])):return key
	if doc.hours<0 or doc.hours>=24 or doc.day<0:return "hours/day range"
	if not doc.get("residents") is Dictionary or doc.residents.size()>256:return "resident count"
	for id in doc.residents:
		var row:Variant=doc.residents[id]
		if not CONTEXT.valid_id(id) or not row is Dictionary or not row.get("region") is String:return "resident "+str(id)
		if not valid_vector(row.get("position")) or not valid_vector(row.get("rotation")):return "resident "+str(id)+" position"
	return ""

## {doc, status, message, notes}: doc is the migrated, usable document or {} (empty slot,
## missing, newer build, or damaged beyond its .previous copy, which is then kept aside).
static func open_save(path:String,world_id:String)->Dictionary:
	var checked:Array=[]
	var loaded:=SAVE_FILE.read_checked(path,MAX_BYTES,func(value:Variant)->String:
		var prepared:=prepare(value,world_id);checked.append(prepared);return prepared.verdict)
	var result:={"doc":{},"status":loaded.status,"message":loaded.message,"notes":[]}
	if loaded.status in ["ok","recovered"]:
		result.doc=checked[-1].doc;result.notes=checked[-1].notes
	return result

func read(path:String)->Dictionary:
	if not _owned(path):return {}
	var opened:=open_save(path,host.context_world_id)
	if opened.message!="":message=opened.message;push_warning("[saves] "+message)
	if not opened.notes.is_empty():opened.doc["load_notes"]=opened.notes
	return opened.doc

func _owned(path:String)->bool:
	return path==directory.path_join("autosave.json") or path in [slot_path(0),slot_path(1),slot_path(2)] or (path.get_base_dir()==directory.path_join("archive") and path.get_file().ends_with(".json")) or (path.get_base_dir()==directory and path.get_file().begins_with("save_") and path.get_file().ends_with(".json"))

## Flat rigs (seated VR, and the AnonPony rig whose camera is the pony's eye a head length ahead)
## are saved by their own place and yaw; the human desktop and room-scale rigs by the camera.
func _flat_rig(body:Node3D)->bool:
	return not host.xr_active and (body.get("form_driver")!=null or body.get("headset_view")==true)

func snapshot()->Dictionary:
	var clock:=get_node("/root/TimeOfDay")
	var camera:Node3D=host._find_camera(host.player)
	var body:Node3D=host.player.get_node("Body") if host.xr_active else host.player
	var at:=Vector3(camera.global_position.x,body.global_position.y,camera.global_position.z)
	var yaw := camera.global_rotation.y
	if _flat_rig(body):at=body.global_position;yaw=body.rotation.y
	var dream: Node = host.get("luna_dream")
	if is_instance_valid(dream):
		var waking: Dictionary = dream.waking_pose()
		if not waking.is_empty(): at = waking.feet; yaw = waking.yaw
	var residents:Dictionary={}
	if is_instance_valid(host.population):
		for id in host.population.saved:
			var row:Dictionary=host.population.saved[id]
			if not valid_vector(vector(row.position)) or not valid_vector(vector(row.rotation)):continue
			residents[id]={"region":row.region,"position":vector(row.position),"rotation":vector(row.rotation)}
			# Restored from the last load and not spawned yet: still out in the world.
			if row.get("resume") is Dictionary:residents[id].merge({"live":true,"state":row.resume.duplicate(true)})
		for id in host.population.live:
			var row:Dictionary=host.population.live[id]
			if not is_instance_valid(row.actor):continue
			# M-SAV-04: one pony with a broken (non-finite) transform made every save of the world
			# fail ("State could not be saved"). She is left out; the load puts her back home.
			if not valid_vector(vector(row.actor.global_position)) or not valid_vector(vector(row.actor.rotation)):
				push_warning("[saves] %s left out of the save: non-finite position"%id);residents.erase(id);continue
			residents[id]={"region":row.region,"position":vector(row.actor.global_position),"rotation":vector(row.actor.rotation),
				"live":true,"state":_resident_state(id,row.actor)}
	if host.inventory.has_method("checkpoint_drops"): host.inventory.checkpoint_drops()
	REGISTRY.flush_live()
	var inv:RefCounted=host.inventory.inventory
	var life_state: Dictionary = host.life.checkpoint() if "life" in host and is_instance_valid(host.life) else {}
	var roster: Dictionary = host.population.config.as_dict() if is_instance_valid(host.population) and "config" in host.population else {}
	var result := {"format":FORMAT,"version":2,"world_id":host.context_world_id,"saved_at":Time.get_unix_time_from_system(),
		"clock":clock.snapshot(),"life":life_state,"population":roster,
		"position":vector(at),"yaw":yaw,"hours":clock.hours,"day":clock.day,
		"residents":residents,"context":host.world_context.snapshot_state(),"story_through":_story_through(),
		"inventory":inv.document(),"books":BOOKS.snapshot(),"paintings":REGISTRY.snapshot(),
		"clothes":host.inventory.clothing.saved.duplicate(true)}
	# The world's scenario stamp (world/modding/scenario.gd), read by menus and load checks.
	var stamp:=SCENARIO.of_doc(result.context)
	if not stamp.is_empty():result["scenario"]=stamp
	# Additive geometry revision. A blocked legacy placement at the original feet
	# remains eligible next load; ordinary movement or successful repair stamps it.
	if not pending_cottage_feet.is_finite() or at.distance_to(pending_cottage_feet) > .001:
		result["cottage_layout_revision"] = COTTAGE_RESUME.REVISION
	if "railway" in host and is_instance_valid(host.railway): result["railway"] = host.railway.checkpoint()
	if "balloon" in host and is_instance_valid(host.balloon):result["balloon"]=host.balloon.checkpoint()
	if "food_world" in host and is_instance_valid(host.food_world): result["food"] = host.food_world.snapshot()
	if "shop_world" in host and is_instance_valid(host.shop_world): result["shops"] = host.shop_world.snapshot()
	if "needs" in host and is_instance_valid(host.needs): result["needs"] = host.needs.snapshot()
	if "wing_flight" in body: result["wing_flight"] = body.wing_flight.snapshot()
	if "apple_bucking" in host and is_instance_valid(host.apple_bucking): result["harvest"] = host.apple_bucking.snapshot()
	# Each resident's place in today's day card (world/life/day/day_runner.gd). Additive, like the
	# residents' "live"/"state": older saves lack them and load as before.
	var day_runner:Node=host.get_node_or_null("DayRunner")
	if day_runner!=null and day_runner.has_method("checkpoint"):result["day_plans"]=day_runner.checkpoint()
	# M-SAV-03: a sky-home pony's afternoon trip home already taken today (NightRest._visits) is
	# not rolled again after a load. Additive: {id: day}.
	var night_rest:Node=host.get_node_or_null("NightRest")
	var visits:Variant=night_rest.get("_visits") if night_rest!=null else null
	if visits is Dictionary:
		var taken:={}
		for id:Variant in visits:
			var visit:Variant=visits[id]
			if id is String and visit is Dictionary and str(visit.get("phase",""))!="" and int(visit.get("day",-1))==int(clock.day):taken[id]=int(clock.day)
		if not taken.is_empty():result["sky_visits"]=taken
	# What the save menus say about it (world/saves/save_catalogue.gd). Additive: no format bump.
	result["summary"] = {"kind":"autosave","place":_place_text(at)}
	return result

## What a pony out in the world was doing that her own systems would not rebuild on load: a follow
## or a rest the player or her AI asked for (pony_action_executor.gd). Bedtime, day-plan steps and
## outings come back through NightRest, DayRunner and the living world; held or flying ponies are
## set down where they were.
func _resident_state(id:String,actor:Node3D)->Dictionary:
	var nav:Node=actor.get_node_or_null("Navigator")
	if nav==null or actor.get("sleeping")==true or actor.has_meta("balloon_passenger"):return {}
	var movement:Dictionary={}
	var director:Node=host.get("director")
	if is_instance_valid(director) and director.get("actions")!=null:
		var found:Variant=director.actions.executors.get(id)
		if is_instance_valid(found) and (found as Node).get("movement") is Dictionary:movement=(found as Node).movement
	var owner:=str(nav.command_owner)
	if owner!="rest_after_command" and (movement.is_empty() or owner!=str(movement.get("id",""))):return {}
	if str(movement.get("type",""))=="follow" and str(movement.get("target_id",""))=="player":
		return {"follow":{"formation":str(movement.get("formation","right")),"distance_m":float(movement.get("distance_m",1.5))}}
	var move:=_saved_move(movement)
	if not move.is_empty():return {"move":move}
	var seating:Node=get_tree().get_first_node_in_group("pony_seating")
	if seating!=null and seating.has_method("phase") and seating.phase(actor)=="seated":return {"rest":"seat"}
	if actor.has_method("posture_status"):
		var requested:=str(actor.posture_status().get("requested",""))
		if requested in ["sit","lie_down"]:return {"rest":requested}
	return {}

## Movement ids the stories own: they resume through their own saved stage, never from here.
const STORY_MOVES:=["arrival","visit","encounter"]
const SAVED_MOVES:=["go_to","lead","approach"]

## M-SAV-03: a walk the player or her AI asked for that was still under way at save time
## (go_to a place, lead Anon somewhere, approach Anon). Re-issued on load by pony_population._resume.
static func _saved_move(movement:Dictionary)->Dictionary:
	var kind:=str(movement.get("type",""))
	if kind not in SAVED_MOVES or str(movement.get("status","")) in ["completed","failed","cancelled","stopped"]:return {}
	var id:=str(movement.get("id",""))
	for prefix:String in STORY_MOVES:
		if id.begins_with(prefix):return {}
	var move:={"type":kind,"ai":bool(movement.get("ai",false))}
	match kind:
		"go_to":
			move.location_id=str(movement.get("location_id",""));move.pace=str(movement.get("pace","walk"))
		"lead":
			if str(movement.get("target_id",""))!="player":return {}
			move.location_id=str(movement.get("location_id",""));move.pace=str(movement.get("pace","walk"))
			move.wait_distance_m=float(movement.get("wait_distance_m",6.0))
		"approach":
			if str(movement.get("target_id",""))!="player":return {}
			move.distance_m=float(movement.get("distance_m",1.5));move.pace=str(movement.get("pace","walk"))
	return _clean_move(move)

## The same shape from an untrusted document, or {}.
static func _clean_move(move:Variant)->Dictionary:
	if not move is Dictionary or str(move.get("type","")) not in SAVED_MOVES:return {}
	var kind:=str(move.type)
	var out:={"type":kind,"ai":move.get("ai")==true,"pace":"trot" if move.get("pace")=="trot" else "walk"}
	if kind in ["go_to","lead"]:
		var place:Variant=move.get("location_id")
		if not place is String or place.is_empty() or place.length()>128 or not _place_id_ok(place):return {}
		out.location_id=place
	if kind=="lead":
		var wait:Variant=move.get("wait_distance_m",6.0)
		out.target_id="player";out.wait_distance_m=clampf(float(wait),3.0,15.0) if (wait is int or wait is float) and is_finite(float(wait)) else 6.0
	if kind=="approach":
		var gap:Variant=move.get("distance_m",1.5)
		out.target_id="player";out.distance_m=clampf(float(gap),1.0,6.0) if (gap is int or gap is float) and is_finite(float(gap)) else 1.5
	return out

static func _place_id_ok(place:String)->bool:
	for c in place:
		if not (c in "abcdefghijklmnopqrstuvwxyz0123456789_:.,-"):return false
	return true

## A restored row's "state" from an untrusted document: only shapes _resume (pony_population) knows.
static func _resume_of(row:Dictionary)->Dictionary:
	var state:Variant=row.get("state",{})
	if not state is Dictionary:return {}
	var moved:=_clean_move(state.get("move"))
	if not moved.is_empty():return {"move":moved}
	var follow:Variant=state.get("follow")
	if follow is Dictionary:
		var formation:=str(follow.get("formation","right"))
		var gap:Variant=follow.get("distance_m",1.5)
		if formation in ["behind","left","right","loose","behind_far"] and (gap is int or gap is float) and is_finite(float(gap)):
			return {"follow":{"formation":formation,"distance_m":clampf(float(gap),1.0,6.0)}}
		return {}
	if state.get("rest") is String and state.rest in ["sit","lie_down","seat"]:return {"rest":str(state.rest)}
	return {}

## Day-card progress (DayRunner.checkpoint) from an untrusted document.
static func _day_plans(value:Variant)->Dictionary:
	var plans:={}
	if not value is Dictionary:return plans
	for id in value:
		var row:Variant=value[id]
		if plans.size()>=256 or not id is String or not CONTEXT.valid_id(id) or not row is Dictionary:continue
		var day:Variant=row.get("day");var index:Variant=row.get("index")
		if not (day is int or day is float) or not (index is int or index is float):continue
		if not is_finite(float(day)) or not is_finite(float(index)) or float(day)<0 or float(day)>1e9 or float(index)<0 or float(index)>64:continue
		plans[id]={"day":int(day),"index":int(index)}
		if row.get("mech") is Dictionary:plans[id].mech=_plan_mech(row.mech)
	return plans

## Sky-home trips already taken ({id: day}) from an untrusted document.
static func _sky_visits(value:Variant)->Dictionary:
	var taken:={}
	if not value is Dictionary:return taken
	for id:Variant in value:
		var day:Variant=value[id]
		if taken.size()>=16 or not id is String or not CONTEXT.valid_id(id) or not (day is int or day is float):continue
		if not is_finite(float(day)) or float(day)<0 or float(day)>1e9:continue
		taken[id]=int(day)
	return taken

## The season, events and station work a day card rolled with (DayRunner._rolled_mech; absent in
## older saves, which roll from the live answers as before).
static func _plan_mech(mech:Dictionary)->Dictionary:
	var out:={}
	var season:Variant=mech.get("season")
	if season is String and CONTEXT.valid_id(season):out.season=season
	for key in ["events","station_needs"]:
		var list:Variant=mech.get(key)
		if not list is Array:continue
		var clean:Array=[]
		for item in list:
			if item is String and CONTEXT.valid_id(item) and clean.size()<32:clean.append(item)
		out[key]=clean
	return out

## "Your home, Ponyville", "Near Sugarcube Corner, Ponyville", "Near Everfree Forest".
func _place_text(at:Vector3)->String:
	var region:Dictionary=preload("res://world/ai/pony_awareness.gd").place_at(at)
	var region_name:=str(region.get("name",""))
	var tail:=", "+region_name if not region_name.is_empty() else ""
	var tree:=get_tree()
	var reference:Node3D=host.player if is_instance_valid(host) and host.get("player") is Node3D else null
	var named:Array=preload("res://world/ui/named_map_places.gd").sample(reference) if reference!=null else []
	var home:Node3D=preload("res://world/buildings/house_interior.gd").at(tree,at)
	if home!=null:
		for entry:Dictionary in named:
			if str(entry.id)==home.place_id():return str(entry.name)+tail
		return "Inside a house"+tail
	var nearest:="";var best:=15.0
	for entry:Dictionary in named:
		var distance:=(entry.position as Vector2).distance_to(Vector2(at.x,at.z))
		if distance<best:best=distance;nearest=str(entry.name)
	if not nearest.is_empty():return "Near "+nearest+tail
	if region_name.is_empty():return ""
	return region_name if bool(region.get("inside",false)) else "Near "+region_name

## Where the player stands now, as a save would name it ("Golden Oak Library, Ponyville").
func place_now()->String:
	if not is_instance_valid(host) or not host.get("player") is Node3D:return ""
	var camera:Node3D=host._find_camera(host.player)
	return _place_text(camera.global_position) if camera!=null else ""

## Menus that cover the view call this as they open: saves made while any is open (including the
## quit save) get the frame the player last saw instead of the menu. release_view when closing.
func remember_view(holder:Object)->void:
	if holder==null:return
	if _view_holders.is_empty():_menu_view=PREVIEW.grab(get_viewport())
	if holder.get_instance_id() not in _view_holders:_view_holders.append(holder.get_instance_id())

func release_view(holder:Object)->void:
	if holder==null:return
	_view_holders.erase(holder.get_instance_id())
	if _view_holders.is_empty():_menu_view=null

## The picture for a save made now: the remembered frame under a menu, else the current frame
## (async when the renderer allows), else false (no picture; any old one is removed).
func _preview_frame(blocking:bool)->Variant:
	if _menu_view!=null:return _menu_view
	if not PREVIEW.available(get_viewport()):return false
	if not blocking:
		var pending:RefCounted=PREVIEW.request(get_viewport())
		if pending!=null:return pending
	var image:Image=PREVIEW.grab(get_viewport())
	return image if image!=null else false

## Rare per-tree transaction: make payout and paid receipt durable in ONE world
## document before publishing the wallet balance. Busy autosaves defer the retry.
func commit_harvest(receipt:String,amount:int,proposed:Dictionary)->bool:
	if busy or restoring or not ready_to_save or not is_instance_valid(host):return false
	if not ("apple_bucking" in host) or not is_instance_valid(host.apple_bucking):return false
	if host.world_context._read_only or not host.inventory.inventory.writable or not host.inventory.clothing.writable:return false
	# The basket pay is the ledger's own (REWARD, or the town calendar's Applebuck Season pay).
	var basket_pay:Variant=host.apple_bucking.ledger.get("reward") if host.apple_bucking.get("ledger") is RefCounted else null
	if amount != (int(basket_pay) if basket_pay is int else APPLE_BUCKING.STATE.REWARD) or not APPLE_BUCKING.valid_snapshot(proposed):return false
	var activity:Node=host.apple_bucking
	var expected:Dictionary=activity.snapshot()
	var found:bool=false
	for id:String in activity.ledger.trees:
		if activity.ledger.receipt(id)!=receipt:continue
		if not activity.ledger.pending_payment(id):return false
		expected.ledger.trees[id].paid=true
		found=true
		break
	if not found or expected!=proposed:return false
	_preserve_autosave(directory.path_join("autosave.json"))
	var doc:Dictionary=snapshot()
	doc.harvest=proposed.duplicate(true)
	busy=true
	var persist:Callable=func(next_inventory:Dictionary)->bool:
		doc.inventory=next_inventory
		_result=OK
		_save_task(directory.path_join("autosave.json"),doc,host.context_world_id)
		return not _invalid and _result==OK
	# One pay path (world/mechanics/ledger.gd): the same checkpointed credit, plus a receipt, a
	# "paid" fact and the "harvested" fact (counters only; shared_activity owns the memory), all
	# staged into doc.context so the one checkpoint holds them. The town pays until the jobs core
	# moves the basket wage to Applejack (WP5).
	var harvested:Dictionary={"actor":"player","target":"applejack","item":"apple","count":1,"ref":receipt,"key":"harvested:"+receipt}
	var opts:Dictionary={"persist":persist,"receipt":receipt,"checkpoint":doc.context,"facts":[["harvested",harvested]]}
	var jobs:Node=JOBS.of(host.get_tree()) if host.is_inside_tree() else null
	if jobs!=null and jobs.get("context")!=host.world_context:jobs=null
	if not LEGACY.old_jobs():
		# Jobs core (row "orchard_bucking"): Applejack pays the basket from her purse, then Big
		# Mac, then the town; the "worked" fact rides in the same checkpoint. `-- --old-jobs`: the town.
		opts["payers"]=JOBS.payers_for(jobs.spec("orchard_bucking").get("payers") if jobs!=null else ["applejack","big_mcintosh","town"],"")
		opts["facts"].append(["worked",{"actor":"player","target":"applejack","item":"apple","count":1,"ref":"orchard_bucking","key":"worked:"+receipt}])
	var paid:bool=LEDGER.transfer(host,"town","player",amount,"harvest",opts).is_empty()
	busy=false
	if paid and jobs!=null and not LEGACY.old_jobs():jobs.count_unit("orchard_bucking","player")
	if paid:
		_timer=0.0
		message="Harvest saved · %d bits earned"%amount
		changed.emit()
	return paid

func save_slot(index:int)->bool:return save_to(slot_path(index),"Slot %d"%(index+1),"manual")

## A new manual save beside the others (the saves browser's "New save", dev 2026-10-27: no more
## three-slot limit). `title` names it in the browser; "" leaves the default name.
func save_new(title:="")->bool:
	if directory=="":return false
	var path:=SHELF.new_save_path(directory)
	if not save_to(path,"“%s”"%SHELF.clean_name(title) if not SHELF.clean_name(title).is_empty() else "Game","manual"):return false
	if not SHELF.clean_name(title).is_empty():SHELF.set_save(path,{"name":title})
	return true
## The arrival's final welcome payment and receipt share one authoritative checkpoint,
## using the same synchronous wallet seam as orchard payments. Completed food grants
## already have per-item story receipts, so a rejected payment never respawns them.
func commit_arrival_welcome(proposed: Dictionary) -> bool:
	if busy or restoring or not ready_to_save or not is_instance_valid(host): return false
	var arrival: Node = host.get("arrival")
	if not is_instance_valid(arrival) or arrival.stage() != "home" or bool(arrival.data.get("furnished", false)): return false
	if host.world_context._read_only or not host.inventory.inventory.writable or not host.inventory.clothing.writable: return false
	var expected: Dictionary = arrival.data.duplicate(true)
	expected.furnished = true
	if proposed != expected or int(proposed.get("welcome_items_granted", 0)) != arrival.BASKET.size(): return false
	_preserve_autosave(directory.path_join("autosave.json"))
	var doc: Dictionary = snapshot()
	doc.context.arrival = proposed.duplicate(true)
	busy = true
	var persist: Callable = func(next_inventory: Dictionary) -> bool:
		doc.inventory = next_inventory
		_invalid = false; _result = OK
		_save_task(directory.path_join("autosave.json"), doc, host.context_world_id)
		return not _invalid and _result == OK
	var paid: bool = LEDGER.transfer(host, "town", "player", arrival.STARTING_BITS, "reward", {"persist": persist}).is_empty()
	busy = false
	if paid: _timer = 0.0
	return paid

func save_to(path:String,label:String,kind:="")->bool:
	if busy or restoring or _quit_writing() or not _owned(path):return false
	if host.world_context._read_only or not host.inventory.inventory.writable or not host.inventory.clothing.writable:
		message="Cannot save while existing state is unreadable.";changed.emit();return false
	_preserve_autosave(path)
	var doc:=snapshot()
	doc.summary.kind=kind if kind in CATALOGUE.KINDS else ("autosave" if path.get_file()=="autosave.json" else "manual")
	# SQLite stays on the main thread; its detached copy is only published with an accepted
	# checkpoint. A rejected/newer checkpoint must keep its own journal, too.
	var journal:=_stage_story(path)
	if not journal.ok:message="Could not copy the story journal; previous save preserved.";changed.emit();return false
	busy=true;_saved_label=label;message="Saving…";changed.emit()
	var frame:Variant=_preview_frame(false)
	_preview_pending=frame if frame is RefCounted and not frame is Image else null
	_task=WorkerThreadPool.add_task(_save_task.bind(path,doc,host.context_world_id,frame,journal.path),false,"Game checkpoint")
	return true

## Validation walks every life and context event, so it runs on the worker beside the
## write. doc is snapshot()'s private copy; nothing else touches it. Its event and memory
## records are shared with the running game, which never edits them, only reads here.
## frame: the screenshot to store beside it (Image, a pending readback, false = none, null =
## leave the existing picture). The menu header sidecar is rewritten after every good write.
func _save_task(path:String,doc:Dictionary,world_id:String,frame:Variant=null,journal_path:String="")->void:
	_story_error=""
	_write_checkpoint(path,doc,world_id,frame,journal_path)
	if journal_path!="" and FileAccess.file_exists(journal_path):DirAccess.remove_absolute(ProjectSettings.globalize_path(journal_path))

func _write_checkpoint(path:String,doc:Dictionary,world_id:String,frame:Variant,journal_path:String)->void:
	_invalid_reason=invalid_reason(doc,world_id)
	_invalid=_invalid_reason!=""
	if _invalid:return
	# Never replace a file a newer build wrote; the player may go back to that build.
	var current:Variant=SAVE_FILE.parse(path,MAX_BYTES)
	if current is Dictionary and format_of(current)>FORMAT:_result=ERR_ALREADY_EXISTS;return
	var previous:Variant=SAVE_FILE.parse(path+".previous",MAX_BYTES)
	if previous is Dictionary and format_of(previous)>FORMAT:_result=ERR_ALREADY_EXISTS;return
	var journal:=path.get_basename()+".story.db"
	var rollback:=journal_path+".previous"
	var had_journal:=FileAccess.file_exists(journal)
	if journal_path!="":
		if had_journal:
			_result=DirAccess.rename_absolute(ProjectSettings.globalize_path(journal),ProjectSettings.globalize_path(rollback))
			if _result!=OK:return
		_result=DirAccess.rename_absolute(ProjectSettings.globalize_path(journal_path),ProjectSettings.globalize_path(journal))
		if _result!=OK:
			if had_journal:_restore_journal(rollback,journal)
			return
	_result=SAVE_FILE.write(path,doc,MAX_BYTES)
	if _result!=OK:
		if journal_path!="":
			# Ordinary write failure: return the exact old companion along with the unchanged
			# JSON. Keep any file whose rollback fails; never claim that the pair was restored.
			if DirAccess.rename_absolute(ProjectSettings.globalize_path(journal),ProjectSettings.globalize_path(journal_path))==OK:
				if had_journal:_restore_journal(rollback,journal)
			else:_story_error=" Journal recovery files remain beside the save."
		return
	if journal_path!="" and had_journal:
		if DirAccess.rename_absolute(ProjectSettings.globalize_path(rollback),ProjectSettings.globalize_path(journal+".previous"))!=OK:
			_story_error=" The previous journal remains in a recovery file beside the save."
	if frame!=null:PREVIEW.store(frame,path)
	CATALOGUE.write_meta(path,SCENARIO.stamp_header(CATALOGUE.header_from_doc(doc,path),doc))

func _restore_journal(source:String,target:String)->void:
	if DirAccess.rename_absolute(ProjectSettings.globalize_path(source),ProjectSettings.globalize_path(target))!=OK:
		_story_error=" Journal recovery files remain beside the save."

## A unique SQLite snapshot is independent of the live connection and safe for the worker.
func _stage_story(path:String)->Dictionary:
	var story:RefCounted=host.world_context.get("story")
	if story==null or not story.is_open():return {"ok":true,"path":""}
	var staged:=path.get_basename()+".story.db.pending-"+Crypto.new().generate_random_bytes(8).hex_encode()
	if story.store.copy_to(staged):return {"ok":true,"path":staged}
	if FileAccess.file_exists(staged):DirAccess.remove_absolute(ProjectSettings.globalize_path(staged))
	return {"ok":false,"path":""}

func archive(path:String)->bool:
	if busy or not _owned(path):return false
	var moved:=_archive_checkpoint(path,SHELF.archive_target(path))
	if moved:message="Moved to archive."
	changed.emit();return moved

## An archived checkpoint goes back among this world's saves, as a manual save.
func unarchive(path:String)->bool:
	if busy or not _owned(path) or path.get_base_dir()!=directory.path_join("archive"):return false
	var problem:=SHELF.move_checkpoint(path,SHELF.restore_target(path))
	message="Back from the archive." if problem=="" else "Could not take it out of the archive: %s."%problem
	changed.emit();return problem==""

## The catalogue intentionally discovers backup-only checkpoints. A backup left at the old
## path would resurrect an archived save as Continue, so the complete file set moves together.
func _archive_checkpoint(path:String,target:String)->bool:
	var problem:=SHELF.move_checkpoint(path,target)
	if problem!="":message="Could not archive save: %s."%problem
	return problem==""

func delete(path:String)->bool:
	if busy or not _owned(path):return false
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(path+".previous"):return false
	var problem:=SHELF.delete_checkpoint(path)
	message="Save deleted." if problem=="" else "Could not delete every save file."
	changed.emit();return problem==""

func archives()->Array[String]:
	var result:Array[String]=[]
	for file in DirAccess.get_files_at(directory.path_join("archive")):
		if file.ends_with(".json"):result.append(directory.path_join("archive").path_join(file))
	result.reverse();return result

func load_save(path:String)->bool:
	if busy or restoring or _quit_writing():return false
	var doc:=read(path)
	if doc.is_empty():changed.emit();return false
	var problem:=scenario_problem(doc)
	if problem!="":message=problem+".";push_warning("[saves] %s not loaded: %s"%[path.get_file(),problem]);changed.emit();return false
	# Preserve the outfit draft until the player explicitly saves/cancels it.
	if host.inventory.customizer.opened:message="Close the wardrobe with Save or Cancel before loading.";changed.emit();return false
	doc["story_source"]=path.get_basename() + ".story.db"
	# The reloaded game.gd opens the world named here; without it a session entered by
	# --world-id or the title's Continue reopened "default", rejected this checkpoint and
	# started a new world with the character creator (player board #50; F8 too).
	var world_before:=requested_world;var fresh_before:=start_fresh
	pending=doc;requested_world=str(host.context_world_id);start_fresh=false;restoring=true
	if is_instance_valid(host.director):host.director.interrupt()
	get_tree().paused=false
	var result:=get_tree().reload_current_scene()
	if result!=OK:
		pending={};requested_world=world_before;start_fresh=fresh_before
		restoring=false;message="Could not reload the game.";changed.emit()
	return result==OK

## A checkpoint of another world from the saved games panel: this world is quit-saved (as when
## leaving it for the title), then the game reloads into the chosen world.
func load_world_save(entry:Dictionary)->bool:
	if busy or restoring or _quit_writing():return false
	if str(entry.get("world_id",""))==host.context_world_id:return load_save(str(entry.get("path","")))
	if host.inventory.customizer.opened:message="Close the wardrobe with Save or Cancel before loading.";changed.emit();return false
	var saved_before:=pending.duplicate();var world_before:=requested_world
	var fresh_before:=start_fresh;var day_before:=fresh_start_day
	if not stage(entry):
		pending=saved_before;requested_world=world_before
		message=(last_problem+".") if last_problem!="" else "That save cannot be loaded (damaged or from a newer version).";changed.emit();return false
	if not save_before_quit():
		pending=saved_before;requested_world=world_before
		start_fresh=fresh_before;fresh_start_day=day_before
		message="Could not save this world; stayed here so you can retry.";changed.emit();return false
	restoring=true
	if is_instance_valid(host.director):host.director.interrupt()
	get_tree().paused=false
	var result:=get_tree().reload_current_scene()
	if result!=OK:
		pending=saved_before;requested_world=world_before
		start_fresh=fresh_before;fresh_start_day=day_before
		restoring=false;_quit_saved=false;message="Could not reload the game.";changed.emit()
	return result==OK

func take_resume()->Dictionary:
	var doc:=pending;pending={}
	_resume_source=""
	_keep_autosave=false
	if not doc.is_empty() and not _same_file(str(doc.get("story_source","")),directory.path_join("autosave.story.db")):
		_keep_autosave=true;_loaded_at=_number(doc.get("saved_at"))
	var fresh:=start_fresh;start_fresh=false
	if doc.is_empty() and not fresh and "--new-game" not in preload("res://world/dev_tools.gd").user_args():
		_resume_source=directory.path_join("autosave.json");doc=read(_resume_source)
	# A resume of another scenario (or vanilla while one runs) is never applied nor archived: the
	# world is not entered at all (game.gd), and the save waits for the right mods.
	scenario_block=scenario_problem(doc) if not doc.is_empty() else ""
	if scenario_block!="":
		message=scenario_block+".";_resume_source="";push_warning("[saves] not resumed: "+scenario_block);changed.emit();return {}
	if not doc.is_empty() and not valid(doc,host.context_world_id):_resume_failed();return {}
	return doc

## A resume that cannot be applied never blocks entering the world: the game starts fresh
## and the autosave it came from moves to the archive (still loadable), so the next
## rolling autosave does not replace it.
func _resume_failed()->void:
	var kept:=""
	if _resume_source!="":
		var target:=directory.path_join("archive").path_join("autosave_not_resumed_%s.json"%SAVE_FILE.stamp())
		if _archive_checkpoint(_resume_source,target):kept=target.get_file().get_basename()
	message="Could not resume the saved game; started fresh."+(" It is kept in the archive as "+kept+"." if kept!="" else "")
	push_warning("[saves] "+message);_resume_source="";changed.emit()

func restore(doc:Dictionary)->bool:
	var prior_restoring:bool=restoring
	restoring=true
	var restored:bool=_restore(doc)
	if not restored:_resume_failed()
	_resume_source=""
	restoring=prior_restoring
	return restored

func _restore(doc:Dictionary)->bool:
	pending_cottage_feet = Vector3.INF
	if not valid(doc,host.context_world_id):return false
	var notes:Array=doc.get("load_notes",[]).duplicate()
	if doc.has("railway") and "railway" in host and is_instance_valid(host.railway):
		var staged_rail := RAIL.new(); staged_rail.configure(host.railway.service.route)
		# An update that changed the line can reject the saved train; drop the train (and
		# plans of ponies riding it) instead of the whole save.
		if not staged_rail.restore(doc.railway):
			doc=doc.duplicate();doc.erase("railway");notes.append("The train was reset.")
			if not doc.life.is_empty() and not _rail_matches(doc):doc.life={};notes.append("Pony plans were reset.")
	if host.world_context._read_only or not host.inventory.inventory.writable or not host.inventory.clothing.writable:return false
	if not host.world_context.restore_checkpoint(doc.context):return false
	_restore_story(doc)
	# These services are created before restore and populated only after startup.
	if "food_world" in host and is_instance_valid(host.food_world):
		if not host.food_world.restore_state(doc.get("food",{})):return false
	if "shop_world" in host and is_instance_valid(host.shop_world) and doc.has("shops"):
		if not host.shop_world.restore_state(doc.shops):return false
	if "needs" in host and is_instance_valid(host.needs) and doc.has("needs"):
		host.needs.restore(doc.needs)
	if "apple_bucking" in host and is_instance_valid(host.apple_bucking) and doc.has("harvest"):
		if not host.apple_bucking.restore(doc.harvest):return false
	var inv:RefCounted=host.inventory.inventory
	if not inv.restore_document(doc.inventory):return false
	if host.inventory.has_method("restore_drops"): host.inventory.restore_drops()
	var clothes:RefCounted=host.inventory.clothing
	clothes.restore(doc.clothes)
	if not clothes.save():return false
	if not BOOKS.restore(doc.get("books", {})):return false
	if not REGISTRY.restore(doc.get("paintings", {})):return false
	var clock:=get_node("/root/TimeOfDay")
	clock.restore_state(doc.clock)
	if not doc.life.is_empty() and "life" in host and is_instance_valid(host.life):
		if not host.life.restore(doc.life):notes.append("Pony plans were reset.")
	if doc.get("balloon") is Dictionary and "balloon" in host and is_instance_valid(host.balloon):
		if not host.balloon.restore(doc.balloon):notes.append("The balloon was reset.")
	var body:CharacterBody3D=host.player.get_node("Body") if host.xr_active else host.player
	if "wing_flight" in body: body.wing_flight.restore(doc.get("wing_flight", {"charge": 8.0}))
	var camera:Node3D=host._find_camera(host.player)
	var destination := unvector(doc.position)
	if preload("res://world/life/luna_dream.gd").is_moon_position(destination):
		# The old dream scene is not rebuilt on load. Use the normal supported spawn;
		# preserve the inventory, clock and story instead of rejecting the checkpoint.
		var spawn: Node3D = host.get("spawn")
		destination = spawn.global_position if is_instance_valid(spawn) else Vector3(camera.global_position.x, body.global_position.y, camera.global_position.z)
		notes.append("Returned to town from an interrupted Luna dream.")
	if host.xr_active:
		body.get_node("XROrigin").rotate_y(float(doc.yaw)-camera.global_rotation.y)
	else:body.rotation.y=float(doc.yaw)
	var feet:=Vector3(camera.global_position.x,body.global_position.y,camera.global_position.z)
	# Flat rigs land by their own feet: seated VR's tracked head is not the rig, and AnonPony's
	# camera (once attached) is the pony's eye ahead of it.
	if _flat_rig(body):feet=body.global_position
	body.global_position+=destination-feet;body.velocity=Vector3.ZERO
	if doc.has("railway") and "railway" in host and is_instance_valid(host.railway):
		if not host.railway.restore(doc.railway):notes.append("The train was reset.")
	restore_residents(doc)
	# Any present marker (including unknown/future values) fails closed for this
	# optional positional repair; it never rejects an otherwise valid checkpoint.
	if not doc.has("cottage_layout_revision") and destination == unvector(doc.position) and COTTAGE_RESUME.is_legacy_floor(destination):
		pending_cottage_feet = destination
	message="Game loaded."+(" "+" ".join(notes) if not notes.is_empty() else "");return true

func restore_residents(doc:Dictionary)->void:
	if is_instance_valid(host.population):
		if not doc.get("population", {}).is_empty() and "config" in host.population:
			host.population.config.apply_data(doc.population)
			host.population.config.save_file(host.population.config_path)
			host.population._stamp = host.population._signature()
		for id in doc.residents:
			var row:Dictionary=doc.residents[id]
			var position := preload("res://world/navigation/roster_placement.gd").recover_saved_depth(unvector(row.position))
			host.population.saved[id]={"region":row.region,"position":position,"rotation":unvector(row.rotation)}
			# Out in the world at save time (newer saves): back on that spot, doing that (pony_population.resuming).
			if row.get("live")==true:host.population.saved[id]["resume"]=_resume_of(row)
		if "resumed_plans" in host.population:host.population.resumed_plans=_day_plans(doc.get("day_plans",{}))
		if "resumed_sky_visits" in host.population:host.population.resumed_sky_visits=_sky_visits(doc.get("sky_visits",{}))

func _process(delta:float)->void:
	if _task>=0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task);_task=-1;busy=false;_preview_pending=null
		if _invalid:push_warning("[saves] state could not be saved: invalid %s"%_invalid_reason)
		message=("State could not be saved." if _invalid else (_saved_label+" saved." if _result==OK else ("Not saved: that file is from a newer version of the game." if _result==ERR_ALREADY_EXISTS else "Save failed; previous file preserved.")))+_story_error;changed.emit()
	# Runs while the pause menu pauses the world (to finish a save); no autosaves then.
	if get_tree().paused or not ready_to_save or not is_instance_valid(host) or not is_instance_valid(host.inventory):return
	_timer+=delta
	if _timer>=60.0 and not busy and not restoring:
		_timer=0.0;save_to(directory.path_join("autosave.json"),"Autosave")

## Write the autosave now, synchronously, bounded by QUIT_BUDGET_MS. Call before any quit
## (menus); the window close request calls it by itself. Once per session.
func save_before_quit()->bool:
	if _quit_saved or restoring or not ready_to_save or not is_instance_valid(host) or not is_instance_valid(host.inventory):return false
	if _quit_writing():return false
	if _quit_thread!=null and _quit_thread.is_started():_quit_thread.wait_to_finish()
	_join_task()
	if host.world_context._read_only or not host.inventory.inventory.writable or not host.inventory.clothing.writable:return false
	var started:=Time.get_ticks_msec()
	var path:=directory.path_join("autosave.json")
	_preserve_autosave(path)
	var doc:=snapshot()
	doc.summary.kind="quit"
	var journal:=_stage_story(path)
	if not journal.ok:return false
	var frame:Variant=_preview_frame(true)
	_invalid=false;_result=OK
	_quit_thread=Thread.new()
	_quit_thread.start(_save_task.bind(path,doc,host.context_world_id,frame,journal.path))
	while _quit_thread.is_alive() and Time.get_ticks_msec()-started<QUIT_BUDGET_MS:OS.delay_msec(5)
	if _quit_thread.is_alive():
		# The write goes to autosave.json.tmp first; if the process ends before the rename,
		# the previous autosave is still intact.
		push_warning("[saves] autosave on quit still writing after %d ms; not waiting"%QUIT_BUDGET_MS);return false
	_quit_thread.wait_to_finish()
	var saved:=not _invalid and _result==OK
	_quit_saved=saved
	print("[saves] autosave on quit: %s in %d ms"%["saved" if saved else "FAILED (%s)"%("invalid "+_invalid_reason if _invalid else error_string(_result)),Time.get_ticks_msec()-started])
	return saved

static func _same_file(a:String,b:String)->bool:
	return ProjectSettings.globalize_path(a).simplify_path()==ProjectSettings.globalize_path(b).simplify_path()

## Called on the main thread before anything writes autosave.json (rolling, quit and the two
## commit paths). Once per session; only when the file on disk is newer than the loaded save.
func _preserve_autosave(path:String)->void:
	if not _keep_autosave or path.get_file()!="autosave.json":return
	_keep_autosave=false
	if not FileAccess.file_exists(path) or float(FileAccess.get_modified_time(path))<=_loaded_at+1.0:return
	var current:Variant=SAVE_FILE.parse(path,MAX_BYTES)
	# A newer build's autosave keeps its existing protection (the write is refused instead).
	if not current is Dictionary or format_of(current)>FORMAT or _number(current.get("saved_at"))<=_loaded_at:return
	var target:=directory.path_join("archive").path_join("autosave_before_load_%s_%d.json"%[SAVE_FILE.stamp(),Time.get_ticks_usec()])
	if _archive_checkpoint(path,target):print("[saves] the newer autosave was kept in the archive as ",target.get_file())

func _quit_writing()->bool:
	return _quit_thread!=null and _quit_thread.is_alive()

func _notification(what:int)->void:
	if what==NOTIFICATION_WM_CLOSE_REQUEST:save_before_quit()

## Block on the running save task; its pending screenshot cannot arrive while this thread waits.
func _join_task()->void:
	if _task<0:return
	if _preview_pending!=null:_preview_pending.cancel()
	WorkerThreadPool.wait_for_task_completion(_task);_task=-1;busy=false;_preview_pending=null

func _exit_tree()->void:
	_join_task()
	if _quit_thread!=null and _quit_thread.is_started() and not _quit_thread.is_alive():_quit_thread.wait_to_finish()


func _story_through()->int:
	var story: RefCounted = host.world_context.get("story") if is_instance_valid(host) else null
	return story.store.last_line_id() if story != null and story.is_open() else 0

## A slot's own journal copy when it has one, else the live journal rolled back to the save.
func _restore_story(doc:Dictionary)->void:
	var story: RefCounted = host.world_context.get("story")
	if story == null or not story.is_open(): return
	var source := str(doc.get("story_source", ""))
	# A copy older than its checkpoint (quit saves before 2026-10-15 wrote none) would lose lines:
	# the live journal rolled back to the checkpoint is then the faithful one.
	var current := source != "" and FileAccess.file_exists(source) and FileAccess.get_modified_time(source) + 5 >= int(_number(doc.get("saved_at")))
	if current and story.store.restore_from(source): return
	if doc.has("story_through"): story.store.rollback(int(doc.story_through))
