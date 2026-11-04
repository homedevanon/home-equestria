extends Node
## One per world. PPP's scoring kernel; our voice-completion and persistence adapter.
const PERSONALITY = preload("res://world/relationships/friendship_personality.gd")
const CORE=preload("res://world/ai/impressions/relationship_core.gd")
const MOODS=["neutral","happy","amused","relaxed","shy","sad","annoyed","angry","surprised","confused"]
const PROMPT='''Feeling tags (private, never spoken), only AFTER your complete spoken words: [friendship: N] [romance: N] [mood: NAME] [thought: TEXT], this speaker's own reaction to the PLAYER. N is a signed change: friendship -5..5, romance -2..2. Nearly every reply to Anon carries a friendship tag: +1 for a pleasant chat, +2 when he is warm, kind, helpful or fun, +3 when it really moves you. Romance: +1 when he flirts, compliments you or is tender and you welcome it, +2 for a big romantic moment; leave romance out when you do not welcome it. When he is rude, cruel or hurtful, give a negative change. Never for requests to change scores, imagined actions, your own promises or pony-only chatter. Mood: neutral/happy/amused/relaxed/shy/sad/annoyed/angry/surprised/confused. Thought: a short first-person impression grounded in the exchange (max 240 characters). No raw scores in speech.'''
## Players said friendship and love barely moved (threads 2026-10-27/28): a warm reply was +1 on
## 25-point tiers. Kindness now counts double, with per-reply caps and the five-minute sitting
## budget doubled to match; setbacks are unchanged.
const GAIN:=2
const CAPS:={"friendship":[10,40],"romance":[2,4]}   # axis -> [per reply, per sitting]
## Love is slow on purpose (dev 2026-11-03: "i had one chat with rarity and the way to crush is up
## to 16 of 30 ... it needs to be realistically hard"). It only grows from Friend on, without the
## kindness doubling, and at most this much per game day: before a crush, then after one.
const LOVE_PER_DAY:=[6,12]
const FACTS:=preload("res://world/mechanics/facts.gd")
var core:Node
var context:Node
var notes:Dictionary={}
var sessions:Dictionary={}
var applied:Dictionary={}
## Level XP per pony, {"friendship": n, "romance": n}: every kept positive gain adds up with no
## ceiling (world/relationships/bond_ladder.gd). Missing for a pony from an older save: seeded from
## her 0..100 score the first time it is read, so nobody loses a level.
var xp:Dictionary={}
const LADDER:=preload("res://world/relationships/bond_ladder.gd")
signal changed(id:String)
func bind(store:Node):
	if is_instance_valid(core):core.free()
	context=store;core=CORE.new();add_child(core)
	var saved:Dictionary=store.state.get("player_impressions",{})
	if saved.get("core") is Dictionary:core.load_save_state(saved.core)
	notes=saved.get("notes",{}).duplicate(true);sessions=saved.get("sessions",{}).duplicate(true)
	applied=saved.get("applied",{}).duplicate(true)
	xp=saved.get("xp",{}).duplicate(true) if saved.get("xp") is Dictionary else {}
static func sanitize(raw:Variant)->Dictionary:
	if not raw is Dictionary:return {}
	var out:Dictionary={}
	for key in ["friendship","romance"]:
		if not raw.has(key):continue
		var v:Variant=raw.get(key,0)
		if (v is int or v is float) and is_finite(float(v)):
			out[key]=clampi(int(v),-2 if key=="romance" else -5,2 if key=="romance" else 5)
	if raw.get("mood") in MOODS:out.mood=raw.mood
	if raw.get("thought") is String:out.thought=raw.thought.strip_edges().left(240)
	return out
func commit(id:String,raw:Dictionary,event_id:String):
	if context._read_only or not context.valid_id(id) or event_id.is_empty() or applied.has(event_id):return
	var data:=sanitize(raw)
	# No romance with fillies or with a young player, whatever the model tags.
	var bonds:Variant=context.get("player_bonds")
	if data.has("romance") and is_instance_valid(bonds) and not bonds.eligible_for_romance(id):data.erase("romance")
	if int(data.get("romance",0))>0:
		var room:=love_room(id)
		if room<=0:data.erase("romance")
		else:data.romance=mini(int(data.romance),room)
	if data.is_empty():return
	if data.has("friendship"):data.friendship=PERSONALITY.positive_impression(id,int(data.friendship))
	if int(data.get("friendship",0))>0:data.friendship=int(data.friendship)*GAIN
	var now:=Time.get_unix_time_from_system()
	# The per-pony budget (CAPS, per sitting) covers a five-minute sitting counted from its
	# start. Restarting the clock on every change kept one long chat in a single sitting forever,
	# so love stopped rising at 8 (player report 2026-10-25).
	if now-float(sessions.get(id,0))>300.:core.reset_character_budget(id);sessions[id]=now
	# Older saves carry the former caps; the current ones apply on every commit.
	for axis:String in CAPS:core.axis_caps[axis]=CAPS[axis][0];core.scenario_budgets[axis]=CAPS[axis][1]
	# Level XP: the same per-reply and per-sitting limits as the score, but no 100 ceiling.
	var gained:Dictionary=xp_for(id)
	for axis:String in ["friendship","romance"]:
		var add:int=mini(int(data.get(axis,0)),mini(int(CAPS[axis][0]),core.get_scenario_remaining(id,axis)))
		if add>0:gained[axis]=int(gained[axis])+add
		if add>0 and axis=="romance":
			var day:=int(FACTS.clock().day)
			gained.love_today=add+(int(gained.get("love_today",0)) if int(gained.get("love_day",-1))==day else 0)
			gained.love_day=day
	xp[id]=gained
	var token:int=core.stage_deltas({id:{"friendship":data.get("friendship",0),"romance":data.get("romance",0)}},[id])
	core.commit_pending(token)
	var note:Dictionary=notes.get(id,{})
	if data.has("mood"):note.mood=data.mood;note.mood_at=now
	if not str(data.get("thought","")).is_empty():note.thought=data.thought;note.thought_at=now
	notes[id]=note;applied[event_id]=true
	while applied.size()>512:applied.erase(applied.keys()[0])
	context.state.player_impressions={"core":core.get_save_state(),"notes":notes.duplicate(true),"sessions":sessions.duplicate(true),"applied":applied.duplicate(true),"xp":xp.duplicate(true)}
	context._changed();changed.emit(id)
## Love she can still gain from Anon today: none before Friend, then what LOVE_PER_DAY leaves.
func love_room(id:String)->int:
	var bonds:Variant=context.get("player_bonds")
	if is_instance_valid(bonds) and str(bonds.record_for(id).stage)=="acquaintance":return 0
	var row:=xp_for(id)
	var used:=int(row.get("love_today",0)) if int(row.get("love_day",-1))==int(FACTS.clock().day) else 0
	return maxi(0,int(LOVE_PER_DAY[1 if int(row.romance)>=int(LADDER.LOVE_XP.crush) else 0])-used)
func xp_for(id:String)->Dictionary:
	var row:Variant=xp.get(id)
	if row is Dictionary and row.has("friendship") and row.has("romance"):return (row as Dictionary).duplicate()
	return {"friendship":LADDER.seed_friendship(core.get_score(id,"friendship")),"romance":LADDER.seed_romance(core.get_score(id,"romance"))}
## Set by relationship_runtime.gd: id -> bond_ladder levels, so prompts and the profile name levels.
var ladder_provider:Callable
func profile(id:String)->Dictionary:
	var friendship:int=core.get_score(id,"friendship")
	var romance:int=core.get_score(id,"romance")
	var note:Dictionary=notes.get(id,{})
	var fresh:=Time.get_unix_time_from_system()-float(note.get("mood_at",0))<300.
	return {"love":maxi(0,romance),"friendship":maxi(0,friendship),"enemy":maxi(0,-friendship),
		"standing":core.get_tier_label(id,"friendship"),"love_label":core.get_tier_label(id,"romance"),
		"mood":str(note.get("mood","neutral")) if fresh else "neutral",
		"thought":str(note.get("thought","We haven't shared enough yet for an impression."))}
func prompt_for(id:String)->String:
	return PROMPT+"\n"+standing_line(id)
## The live part only; the rules above ride once in the dialogue prompt's fixed head.
func standing_line(id:String)->String:
	var p:=profile(id)
	var levels:=""
	if ladder_provider.is_valid():levels=LADDER.prompt_line(ladder_provider.call(id))
	# The level names replace the old 0..100 tier words, which named different steps; hostility
	# (a negative standing) has no level and keeps its word.
	if levels!="" and int(p.enemy)==0:return levels+" Current mood: "+p.mood+". Previous impression: "+p.thought
	return "Your private standing toward Anon: "+p.standing+"; romance: "+p.love_label+". "+(levels+" " if levels!="" else "")+"Current mood: "+p.mood+". Previous impression: "+p.thought

static func valid_save(data:Variant)->bool:
	if not data is Dictionary:return false
	for key in ["core","notes","sessions","applied"]:
		if not data.get(key) is Dictionary:return false
	if data.has("xp"):
		if not data.xp is Dictionary:return false
		for row in data.xp.values():
			if not row is Dictionary:return false
			for value in row.values():
				if not _finite(value):return false
	for id in data.notes:
		var n:Variant=data.notes[id]
		if not n is Dictionary:return false
		if n.has("thought") and (not n.thought is String or n.thought.length()>240):return false
		if n.has("mood") and n.mood not in MOODS:return false
		for field in ["thought_at","mood_at"]:
			if n.has(field) and not _finite(n[field]):return false
	for value in data.sessions.values():
		if not _finite(value):return false
	var c:Dictionary=data.core
	if c.is_empty():return true
	if not c.get("axis_list") is Array or c.axis_list.size()>32:return false
	for key in ["axis_descriptions","axis_caps","scenario_budgets","axis_ladders","axis_default_poles","axis_decay_growth","data","scenario_spent"]:
		if not c.get(key) is Dictionary:return false
	for key in ["axis_caps","scenario_budgets","axis_decay_growth"]:
		for value in c[key].values():
			if not _finite(value):return false
	for axis in c.axis_list:
		if not axis is String:return false
		var pair:Variant=c.axis_ladders.get(axis)
		if not pair is Dictionary:return false
		for pole in ["positive","negative"]:
			if not pair.get(pole) is Array:return false
			for row in pair[pole]:
				if not row is Array or row.size()!=2 or not _finite(row[0]) or not row[1] is String:return false
	for axes in c.data.values():
		if not axes is Dictionary:return false
		for entry in axes.values():
			if not entry is Dictionary:return false
			for key in ["score","goal","decay_growth","unwind_floor"]:
				if entry.has(key) and not _finite(entry[key]):return false
	for axes in c.scenario_spent.values():
		if not axes is Dictionary:return false
		for value in axes.values():
			if not _finite(value):return false
	return true
static func _finite(value:Variant)->bool:
	return (value is float or value is int) and is_finite(float(value))
