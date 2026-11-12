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
## M-AI-14: Settings "relationship/pace" scales the kind gains above (GAIN, the CAPS, LOVE_PER_DAY and
## love gains); setbacks are unchanged. Missing or null = 1.0 = the numbers above, unchanged.
const PACE_KEY:="relationship/pace"
const PACE_RANGE:=[0.25,4.0]
## M-AI-15 first pass (dev's Later spec, NEXT_STEPS Oct 25). Numbers for the dev to tune, all here.
## Grudge: per pony, 0..100, shown in her profile as Hostility. Ponies are forgiving: it falls with
## game time, kindness and apologies much faster than it rises.
## Notoriety: one town-wide score for cruelty to the mares; town talk (town_talk.gd spread_notoriety)
## passes it on in pony chats, and a pony who heard of it is wary of him before they ever meet.
const GRUDGE:={
	"per_hurt":8.0,          # grudge per point of negative friendship she tags
	"max":100.0,
	"decay_per_hour":6.0,    # per game hour
	"kindness":5.0,          # off per point of positive friendship
	"apology":25.0,          # off when he says sorry to her (conversation_director.gd)
	"apology_every_s":120.0, # one apology counts per pony this often (real seconds)
	"prompt_at":15.0,        # her prompt names the grudge from this value
}
const NOTORIETY:={
	"min_hurt":2,            # a negative friendship change of at least this is a deed
	"per_hurt":3.0,          # notoriety per point of such a change
	"hit_extra":6.0,         # more when the deed was rough handling (thrown, smacked)
	"max":100.0,
	"decay_per_day":4.0,     # per game day
	"heard_at":8.0,          # a pony who heard this much reacts (her prompt, her profile)
	"retell":0.8,            # what a listener hears of what the teller knows
	"deeds":6,               # newest deeds kept
}
## Event ids that are not cruelty (being stood up, a refused offer): grudge only, no notoriety.
const NOT_DEEDS:=["appt:","refused_"]
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
## M-AI-15: id -> {"v": grudge, "at": game day float}; read through grudge().
var grudges:Dictionary={}
## M-AI-15: {"score", "at", "deeds": [{"victim","kind","text","day"}], "heard": {id: {"v","day"}}}.
var notoriety:Dictionary={}
var _apologies:Dictionary={}
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
	grudges=saved.get("grudge",{}).duplicate(true) if saved.get("grudge") is Dictionary else {}
	notoriety=saved.get("notoriety",{}).duplicate(true) if saved.get("notoriety") is Dictionary else {}
## M-AI-14: the relationship pace from Settings (null-checked; 1.0 = today's numbers).
static func pace()->float:
	var tree:=Engine.get_main_loop() as SceneTree
	var settings:Node=tree.root.get_node_or_null("Settings") if tree!=null and tree.root!=null else null
	var value:Variant=settings.call("get_value",PACE_KEY) if settings!=null and settings.has_method("get_value") else null
	if not (value is float or value is int) or not is_finite(float(value)):return 1.0
	return clampf(float(value),float(PACE_RANGE[0]),float(PACE_RANGE[1]))
## CAPS[axis][index] at this pace (index 0 per reply, 1 per sitting).
static func cap(axis:String,index:int,p:=1.0)->int:
	var base:int=int(CAPS[axis][index])
	return base if is_equal_approx(p,1.0) else maxi(1,roundi(float(base)*p))
static func paced_gain(value:int,p:float)->int:
	return value if is_equal_approx(p,1.0) or value<=0 else maxi(1,roundi(float(value)*p))
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
	var p:=pace()
	if int(data.get("romance",0))>0:
		var room:=love_room(id)
		if room<=0:data.erase("romance")
		else:data.romance=mini(paced_gain(int(data.romance),p),room)
	if data.is_empty():return
	if data.has("friendship"):data.friendship=PERSONALITY.positive_impression(id,int(data.friendship))
	if int(data.get("friendship",0))>0:data.friendship=paced_gain(int(data.friendship)*GAIN,p)
	_feel_grudge(id,int(data.get("friendship",0)),event_id,str(raw.get("deed","")))
	var now:=Time.get_unix_time_from_system()
	# The per-pony budget (CAPS, per sitting) covers a five-minute sitting counted from its
	# start. Restarting the clock on every change kept one long chat in a single sitting forever,
	# so love stopped rising at 8 (player report 2026-10-25).
	if now-float(sessions.get(id,0))>300.:core.reset_character_budget(id);sessions[id]=now
	# Older saves carry the former caps; the current ones apply on every commit.
	for axis:String in CAPS:core.axis_caps[axis]=cap(axis,0,p);core.scenario_budgets[axis]=cap(axis,1,p)
	# Level XP: the same per-reply and per-sitting limits as the score, but no 100 ceiling.
	var gained:Dictionary=xp_for(id)
	for axis:String in ["friendship","romance"]:
		var add:int=mini(int(data.get(axis,0)),mini(cap(axis,0,p),core.get_scenario_remaining(id,axis)))
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
	_save()
	changed.emit(id)
func _save()->void:
	context.state.player_impressions={"core":core.get_save_state(),"notes":notes.duplicate(true),"sessions":sessions.duplicate(true),"applied":applied.duplicate(true),"xp":xp.duplicate(true),
		"grudge":grudges.duplicate(true),"notoriety":notoriety.duplicate(true)}
	context._changed()
## Love she can still gain from Anon today: none before Friend, then what LOVE_PER_DAY leaves.
func love_room(id:String)->int:
	var bonds:Variant=context.get("player_bonds")
	if is_instance_valid(bonds) and str(bonds.record_for(id).stage)=="acquaintance":return 0
	var row:=xp_for(id)
	var used:=int(row.get("love_today",0)) if int(row.get("love_day",-1))==int(FACTS.clock().day) else 0
	return maxi(0,paced_gain(int(LOVE_PER_DAY[1 if int(row.romance)>=int(LADDER.LOVE_XP.crush) else 0]),pace())-used)

# --- M-AI-15 grudge and notoriety -----------------------------------------------------------------

static func _days()->float:
	var clock:Variant=FACTS.clock()
	return float(clock.day)+float(clock.hours)/24.0 if clock!=null else 0.0
## Her grudge against Anon now, 0..GRUDGE.max (decayed with game time since it last changed).
func grudge(id:String)->float:
	var row:Variant=grudges.get(id)
	if not row is Dictionary:return 0.0
	var hours:=maxf(0.0,(_days()-float(row.get("at",0.0)))*24.0)
	return maxf(0.0,float(row.get("v",0.0))-hours*float(GRUDGE.decay_per_hour))
func _set_grudge(id:String,value:float)->void:
	if value<=0.0:grudges.erase(id)
	else:grudges[id]={"v":minf(value,float(GRUDGE.max)),"at":_days()}
## A friendship change: hurt raises the grudge (and may be a deed), kindness wears it down.
func _feel_grudge(id:String,friendship:int,event_id:String,deed:String)->void:
	if friendship<0:
		_set_grudge(id,grudge(id)+float(-friendship)*float(GRUDGE.per_hurt))
		if -friendship>=int(NOTORIETY.min_hurt) and NOT_DEEDS.all(func(prefix:String)->bool:return not event_id.begins_with(prefix)):
			note_deed(id,deed if not deed.is_empty() else ("letter" if event_id.begins_with("letter:") else "cruel"),float(-friendship),false)
	elif friendship>0 and grudges.has(id):
		_set_grudge(id,grudge(id)-float(friendship)*float(GRUDGE.kindness))
## He said sorry to her (conversation_director.gd). Counted once per GRUDGE.apology_every_s.
func apologised(id:String)->bool:
	if context==null or context._read_only or grudge(id)<=0.0:return false
	var now:=Time.get_ticks_msec()*.001
	if now-float(_apologies.get(id,-1e9))<float(GRUDGE.apology_every_s):return false
	_apologies[id]=now
	_set_grudge(id,grudge(id)-float(GRUDGE.apology))
	_save();changed.emit(id)
	return true
## The town-wide notoriety now (decayed per game day).
func notoriety_score()->float:
	var days:=maxf(0.0,_days()-float(notoriety.get("at",0.0)))
	return maxf(0.0,float(notoriety.get("score",0.0))-days*float(NOTORIETY.decay_per_day))
## A cruel deed against `victim` ("cruel", "hit", "letter", or a caller's own kind such as "cheat").
## Public so other systems (player_bonds cheating, a future hit detector) can add theirs.
func note_deed(victim:String,kind:String,weight:float,save:=true)->void:
	if context==null or context._read_only:return
	var add:=weight*float(NOTORIETY.per_hurt)+(float(NOTORIETY.hit_extra) if kind=="hit" else 0.0)
	notoriety.score=minf(float(NOTORIETY.max),notoriety_score()+add)
	notoriety.at=_days()
	var deeds:Array=notoriety.get("deeds",[])
	deeds.append({"victim":victim,"kind":kind.left(20),"text":deed_text(kind,victim),"day":int(floorf(_days()))})
	while deeds.size()>int(NOTORIETY.deeds):deeds.pop_front()
	notoriety.deeds=deeds
	# The one he hurt knows it first-hand.
	_heard(victim,notoriety_score())
	if save:_save();changed.emit(victim)
func deed_text(kind:String,victim:String)->String:
	var who:=victim.replace("_"," ").capitalize()
	match kind:
		"hit":return "Anon roughed up %s" % who
		"letter":return "Anon sent %s a nasty letter" % who
		"cheat":return "Anon cheated on %s" % who
	return "Anon was cruel to %s" % who
func _heard(id:String,value:float)->void:
	var heard:Dictionary=notoriety.get("heard",{})
	heard[id]={"v":maxf(value,heard_notoriety(id)),"day":_days()}
	notoriety.heard=heard
## What `id` has heard of his notoriety (decayed like the score itself).
func heard_notoriety(id:String)->float:
	var row:Variant=(notoriety.get("heard",{}) as Dictionary).get(id) if notoriety.get("heard") is Dictionary else null
	if not row is Dictionary:return 0.0
	return maxf(0.0,minf(notoriety_score(),float(row.get("v",0.0))-maxf(0.0,_days()-float(row.get("day",0.0)))*float(NOTORIETY.decay_per_day)))
## town_talk.gd: `teller` passes on what she knows to `listener`; true when the listener learned more.
func retell(teller:String,listener:String)->bool:
	if context==null or context._read_only or teller==listener:return false
	var known:=heard_notoriety(teller)
	var passed:=known*float(NOTORIETY.retell)
	if passed<float(NOTORIETY.heard_at) or heard_notoriety(listener)>=passed-1.0:return false
	_heard(listener,passed)
	_save();changed.emit(listener)
	return true
## The newest deed text, "" when none.
func latest_deed()->String:
	var deeds:Array=notoriety.get("deeds",[]) if notoriety.get("deeds") is Array else []
	return str((deeds[-1] as Dictionary).get("text","")) if not deeds.is_empty() and deeds[-1] is Dictionary else ""
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
		"thought":str(note.get("thought","We haven't shared enough yet for an impression.")),
		# M-AI-15: the forgiving grudge (pony_profile_view.gd shows it as Hostility) and what she heard.
		"hostility":roundi(grudge(id)),"heard":heard_about(id)}
func prompt_for(id:String)->String:
	return PROMPT+"\n"+standing_line(id)
## The live part only; the rules above ride once in the dialogue prompt's fixed head.
func standing_line(id:String)->String:
	var p:=profile(id)
	var levels:=""
	if ladder_provider.is_valid():levels=LADDER.prompt_line(ladder_provider.call(id))
	# The level names replace the old 0..100 tier words, which named different steps; hostility
	# (a negative standing) has no level and keeps its word.
	if levels!="" and int(p.enemy)==0:return levels+" Current mood: "+p.mood+". Previous impression: "+p.thought+_feud_line(id)
	return "Your private standing toward Anon: "+p.standing+"; romance: "+p.love_label+". "+(levels+" " if levels!="" else "")+"Current mood: "+p.mood+". Previous impression: "+p.thought+_feud_line(id)
## M-AI-15, only while there is something to say (every token is paid): her grudge, and the town
## talk she heard about him. "" otherwise.
func _feud_line(id:String)->String:
	var out:=""
	var held:=grudge(id)
	if held>=float(GRUDGE.prompt_at):out+=" You hold a grudge against Anon (%d/100); it fades with time, kindness and apologies." % roundi(held)
	var heard:=heard_about(id)
	if not heard.is_empty():out+=" Town talk you heard: %s; you are wary of him." % heard
	return out
## The town talk `id` heard about him (the newest deed), "" when she heard too little or was hurt
## herself (her own story is no gossip to her).
func heard_about(id:String)->String:
	var deeds:Array=notoriety.get("deeds",[]) if notoriety.get("deeds") is Array else []
	if deeds.any(func(row:Variant)->bool:return row is Dictionary and str(row.get("victim",""))==id):return ""
	return latest_deed() if heard_notoriety(id)>=float(NOTORIETY.heard_at) else ""

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
	# M-AI-15, optional (older saves have neither).
	if data.has("grudge"):
		if not data.grudge is Dictionary:return false
		for row in data.grudge.values():
			if not row is Dictionary or not _finite(row.get("v",0)) or not _finite(row.get("at",0)):return false
	if data.has("notoriety"):
		if not data.notoriety is Dictionary:return false
		for key in ["score","at"]:
			if data.notoriety.has(key) and not _finite(data.notoriety[key]):return false
		if data.notoriety.has("deeds") and not data.notoriety.deeds is Array:return false
		if data.notoriety.has("heard") and not data.notoriety.heard is Dictionary:return false
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
