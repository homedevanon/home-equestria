extends RefCounted
## Physical contact reactions: boops, pets, kisses and handling batched into one optional reply, plus touch memories.
## Split out of conversation_director.gd (2026-10-13); the host keeps forwards for every name reachable
## from elsewhere, so callers did not change. `host` is the owning conversation_director node; shared state stays there.

## Contact is batched per pony (dev 2026-09-28: tens of boops a second). One summary reaches
## the model once the contact pauses, or after CONTACT_BATCH_MAX seconds; a pony reacts to
## contact at most once per CONTACT_COOLDOWN. A welcomed mouth kiss can interrupt a reply already on its way.
const CONTACT_KINDS := ["boop","hoofhold","petted","flank_smack","kiss","kiss_refused","deep_kiss","hug"]
const CONTACT_PAUSE := 1.2
const CONTACT_BATCH_MAX := 6.0
const CONTACT_COOLDOWN := 8.0
const CONTACT_STALE := 20.0
const CRADLE_REST := preload("res://world/characters/locomotion/cradle_rest.gd")
const BOND := preload("res://world/relationships/bond_rules.gd")
const BOND_PROMPT := preload("res://world/relationships/bond_prompt.gd")

var host: Node
var _remembered_contacts:Dictionary={}
## Relationship overhaul 2026-11-21: the touch kinds of the batch a contact turn is about to answer.
var _turn_kinds:Dictionary={}


func _init(owner_node: Node) -> void:
	host = owner_node


func _remember_touch(kind:String,id:String)->void:
	if kind.begins_with("anon_resting"):return # He lay down nearby; not a touch.
	var key:=id+":"+kind
	if host._now()-float(_remembered_contacts.get(key,-100.))<10.:return
	_remembered_contacts[key]=host._now()
	var what:=kind if not kind.begins_with("petted:") else "petting your "+_pet_words(kind.get_slice(":",1))
	if kind=="snowball_hit":what="hitting you with a snowball"
	host.world_context.record("physical_contact","The player made contact with you: "+what+". This alone does not establish how you felt about it.",[id],["player",id])


func _remember_outcome(event:Dictionary,id:String)->void:
	if host._invalidating_world: return
	if event.status not in ["completed","failed","cancelled","accepted"]:return
	var kind:="intention" if event.status=="accepted" else "action_outcome"
	var text:="%s: %s (%s). %s"%[event.type,event.status,event.id,event.reason]
	if kind=="intention":text+=" This was an intention, not proof of completion; active commands do not survive a restart."
	host.world_context.record(kind,text,[id],[id])


func reaction_chance(kind:String) -> float:
	if kind in ["carried", "carried_away", "sprayed", "thrown"] or kind.begins_with("anon_resting"): return 1.0
	if kind.begins_with("petted"):return .3
	# A snowball from Anon (W2-SEAS-F; only player-thrown hits emit it): usually worth a word.
	if kind == "snowball_hit": return .7
	match kind:
		"flank_smack", "kiss_refused": return 1.0
		"deep_kiss": return .8
		"kiss": return .6
		"hug": return .5
		"quiet": return .55
		"hoofhold": return .4
		"boop": return .2
	return 0.0


## Body region names from pony_touch_body.gd in words for the model.
static func _pet_words(region:String) -> String:
	return {"barrel":"side","leg":"leg","wing":"wing","withers":"withers"}.get(region,region if region!="" else "coat")


## Optional response to an actual contact, never fabricated player speech.
## Busy turns and an active microphone take priority; no stale reaction queue.
func _on_physical_reaction(kind:String,id:String,deferred:bool=false,summary:="") -> void:
	if kind == "quiet" and host._authored_holds(id): return
	# Petting arrives as "petted:<region>" (pony_touch_body.gd, one per petting session).
	var pet_region:=""
	if kind.begins_with("petted"):
		pet_region=kind.get_slice(":",1);kind="petted"
	if kind == "kiss" and host.characters.has(id):
		var actor: Node = host.characters[id].node
		if is_instance_valid(actor) and actor.get("identity") != null and not actor.identity.filly:
			kiss_started(id)
			return
	if kind == "deep_kiss": return
	if kind in ["quiet", "carried", "carried_away", "boop", "petted", "hoofhold", "hug"] and quiet_moment(id): return
	if kind in CONTACT_KINDS:
		_log_contact(id,kind,pet_region);return
	if not host.characters.has(id):_lost(kind,id);return
	if not is_instance_valid(host.player_head) or not is_instance_valid(host.characters[id].node):_lost(kind,id);return
	if not host.awareness.can_hear(host.characters[id].node,host.player_head,host._earshot(id)):_lost(kind,id);return
	if host.state!="idle" or host.speech.state=="hearing":
		if (kind in ["carried", "carried_away", "sprayed", "thrown", "snowball_hit"] or kind.begins_with("anon_resting")) and not deferred:
			host._pending_contacts[id] = {"kind": kind, "until": host._now() + 12.0}
		_lost(kind,id)
		return
	if kind not in ["farewell","contact"] and host._reaction_rng.randf()>=reaction_chance(kind):return
	host._current=id;host._listener_id="player";host._turn_id+=1;host._rewrite_used=false;host._recorded=false
	if kind=="contact":_bond_turn(id)
	# Conversation clock: a fresh chat starts after two quiet minutes; the situation block
	# suggests sitting or lying down once a chat has run a while (dev, 2026-09-16).
	if kind!="quiet" and kind!="farewell":
		if host._now()-float(host.characters[id].get("chat_last",-1e9))>120.0:host.characters[id]["chat_since"]=host._now()
		host.characters[id]["chat_last"]=host._now()
	host._pending_text="";host._pending_actions=[];host._player_text=""
	host._set_attention(id,host.player_head)
	host.state="thinking";host.speech.set_muted(false);host._show_indicator("thinking");host.hud.set_state("thinking","")
	var event:=summary
	if kind == "carried": event = "Anon has been holding you off the ground in his hands for over five seconds. You can just enjoy being held in silence, or say a word or two if it adds something. Do not make up where he is taking you."
	if kind == "carried_away": event = "Anon has picked you up in his hands and is walking away with you. You don't know where he's going or what he's up to yet. Feel free to enjoy the ride in silence and only speak if something needs to be said."
	if kind.begins_with("carried") and CRADLE_REST.cradled(host.characters[id].node): event = CRADLE_REST.CARRIED_EVENT if kind == "carried" else CRADLE_REST.CARRIED_AWAY_EVENT
	if kind == "thrown": event = _thrown_event(id)
	# Cuddling is her choice (dev 2026-09-28): the bed or couch only tells her he is lying there.
	if kind.begins_with("anon_resting"): event = "Anon is lying on the %s a few steps away, resting. If you want to cuddle with him, say so and use [cuddle]. You can also just talk to him or leave him be." % kind.get_slice(":", 1)
	if kind == "sprayed": event = "Anon just spritzed you with plain water from a small spray bottle, leaving a damp spot on your coat. Give a quick reaction in character to the water."
	if kind == "snowball_hit": event = "Anon just hit you with a snowball; snow is on your coat. React briefly in character: laugh, protest, or promise payback. You may throw one back if your actions allow it."
	if kind=="quiet":event="The player has been quiet since your last reply. Sometimes just relish the moment with them: comfortable silence is a complete answer, so reply with only [silence], above all if you already asked a question. Speak only with a reason: a few natural words, then wait; never continue a monologue, restart your last topic or invent a project from the scenery. You may bring up something new instead. " + preload("res://world/ai/chatter_topics.gd").seed_line()
	if kind=="farewell":
		event="The conversation has run its course: "+host._farewell_reason+" What you do next is up to you, even at bedtime. Usually you say a quick goodbye in your own way and go on with your day using go_to, go_home or resume_routine, without needing to explain where you are going or why. If you would rather stay with the player for a good talk or a nice moment with a friend, say so and use [stay], or [follow: player] if he is walking off. Say something aloud rather than replying with [silence]."
		# Another mare's goodbye moments ago: hers must not sound the same (dev 2026-10-26).
		var last: Dictionary = host._last_farewell
		if str(last.id) != id and host._now() - float(last.at) < 180.0 and not str(last.text).is_empty():
			event += " %s just said goodbye with: \"%s\". Word yours completely differently: different opening, length and structure, and not the same plan or place." % [str(host.characters[last.id].profile.get("name", last.id)) if host.characters.has(last.id) else "Another pony", str(last.text).left(160)]
	var runtime: Node = host.get_tree().get_first_node_in_group("encounters")
	if runtime != null and kind != "farewell" and kind != "quiet": runtime.event(id, kind, event.left(160) if not event.is_empty() else kind.replace("_", " "))
	var messages:Array=host.characters[id].history.duplicate(true)
	host._physical_context=host.time_gap_note(id)+("[Your situation, not spoken dialogue] " if kind=="farewell" else "[Observed physical event, not spoken dialogue] ")+event
	var instruction:=" LESS IS MORE: one or two words, or only [silence], are often enough; longer chatter only when the moment invites it, not after every touch. Do not repeat this instruction."
	messages.append({"role":"user","content":host._physical_context+instruction})
	# Contact and handling are the player's doing too: they take the connection.
	if not await host._take_llm():
		_lost(kind,id)
		return
	var contact_prompt: String = host.system_prompt(id)
	host._trace_request("contact:" + kind, id, contact_prompt, messages)
	host._label_next("lull" if kind == "quiet" else "farewell" if kind == "farewell" else "contact_" + kind.get_slice(":", 0))
	if not host.llm.complete(contact_prompt,messages,host._on_reply.bind(host._turn_id)):host._fail("llm busy")


## A wanted mouth kiss replaces her words. Cancel providers and stale callbacks as well as audio.
func kiss_started(id: String) -> void:
	if host.participant_busy(id): host.interrupt()
	if host.characters.has(id):
		var actor: Node = host.characters[id].node
		if is_instance_valid(actor) and actor.has_method("stop_speaking"): actor.stop_speaking()
		host.characters[id]["lull_used"] = host.characters[id].get("chat_last", -1.0)
	if host._contact_log.erase(id): _bond_dropped(id)
	host._pending_contacts.erase(id)
	host._contact_next[id] = host._now()+CONTACT_COOLDOWN


func quiet_moment(id: String) -> bool:
	if not host.characters.has(id) or not is_instance_valid(host.characters[id].node): return false
	var affection: Node = host.characters[id].node.get_node_or_null("Affection")
	return affection != null and (affection.kind == "kiss" or float(affection.get("afterglow_left")) > 0.0)


func _log_contact(id:String,kind:String,region:String) -> void:
	var entry:Dictionary=host._contact_log.get(id,{"first":host._now(),"counts":{},"regions":{}})
	entry.last=host._now()
	entry.counts[kind]=int(entry.counts.get(kind,0))+1
	if not region.is_empty():entry.regions[region]=true
	host._contact_log[id]=entry
	host.vocal.prepare(id)


func _flush_contacts() -> void:
	for id:String in host._contact_log.keys():
		var entry:Dictionary=host._contact_log[id]
		if not host.characters.has(id) or not is_instance_valid(host.characters[id].node) or host._now()-float(entry.last)>CONTACT_STALE:
			host._contact_log.erase(id);_bond_dropped(id);continue
		if host._now()-float(entry.last)<CONTACT_PAUSE and host._now()-float(entry.first)<CONTACT_BATCH_MAX:continue
		# A kiss owns the moment; do not build a deferred contact monologue.
		if host.characters[id].node.has_meta("affection_active"):
			host._contact_log.erase(id);_bond_dropped(id);continue
		if host._now()<float(host._contact_next.get(id,0.0)) or host.state!="idle" or host.speech.state=="hearing":continue
		host._contact_log.erase(id)
		host._contact_next[id]=host._now()+CONTACT_COOLDOWN
		# Each touch is another chance to be noticed: a single boop often passes, a flurry does not.
		var unnoticed:=1.0
		for kind:String in entry.counts:
			unnoticed*=pow(1.0-reaction_chance(kind),float(entry.counts[kind]))
		if host._reaction_rng.randf()>=1.0-unnoticed:
			_bond_dropped(id)
			continue
		_turn_kinds[id]=entry.counts.keys()
		_on_physical_reaction("contact",id,true,_contact_summary(id,entry))
		return


func _contact_summary(id:String,entry:Dictionary) -> String:
	var filly:bool=host.characters[id].node.identity.filly
	var words:={"boop":"booped your nose","hoofhold":"held your hoof","petted":"petted you","flank_smack":"smacked your flank",
		"kiss":"gave you a gentle kiss on the forehead" if filly else "kissed you","kiss_refused":"tried to kiss you when you had not welcomed it","deep_kiss":"kissed you mouth to mouth and held the kiss","hug":"hugged you"}
	var parts:Array[String]=[]
	for kind:String in entry.counts:
		var n:int=int(entry.counts[kind])
		var what:String=words[kind]
		if kind=="petted" and not entry.regions.is_empty():what="petted your "+", ".join(entry.regions.keys().map(host._pet_words))
		parts.append(what+(" once" if n==1 else " %d times"%n))
	var text:="Over the last %d seconds Anon %s." % [ceili(maxf(1.0,float(entry.last)-float(entry.first))),", ".join(parts)]
	if entry.counts.has("boop"):
		text+=" Boops tickle and make you giggle." if filly else " Secretly, you love nose boops. Even if you pretend to protest, they leave you warm, giddy and flustered. A whole flurry of them flusters you far more than it annoys you."
	if entry.counts.has("petted"):
		text+=" Being petted feels nice and affectionate. You enjoy it unless you are deeply upset with Anon."
	var runtime:Node=host.get_tree().get_first_node_in_group("player_relationships")
	# Relationship overhaul 2026-11-21 (design section 8): no stage-written paragraphs; her block says
	# where they stand, and the contact turn ends with what happened to a touch she turned away.
	if BOND.DYNAMIC: return _bond_summary(text,runtime,id,entry)
	var stage:=str(runtime.bonds.record_for(id).stage) if runtime!=null and is_instance_valid(runtime.bonds) else ""
	var partner:bool=stage in ["dating","engaged","married"]
	# THREAD_FIX_RELATIONSHIP 2026-11-19: a kiss the game turned away while nothing bars her own kiss
	# (no anger, no request for space) is hers to judge: she may want it after all (dev 2026-11-15:
	# "The llm SHOULD have agency"). Her [kiss_player] then happens and counts (37 tokens, this turn only).
	if entry.counts.has("kiss_refused") and not partner and runtime!=null and preload("res://world/relationships/romance_rules.gd").FACTS and runtime.can_kiss_player(id):
		text=text.replace("tried to kiss you when you had not welcomed it","leaned in to kiss you, and taken by surprise you turned your face away")
		text+=" If you wanted that kiss, say so, or kiss him yourself with [kiss_player]. Otherwise, tell him no in your own way."
	if partner and (entry.counts.has("kiss") or entry.counts.has("deep_kiss")):
		text+=" You are in love with Anon. You welcome his kisses and want to kiss him back, and a shower of kisses can leave you quietly melting. You can just enjoy it in silence, or say a word or two instead of a whole speech. Never scold him for kissing you or ask him to warn you first. To kiss him yourself, use [kiss_player], with a short line if you want."
	text+=" Decide how you feel based on your personality and your bond with Anon, then show it in your words, face tag and impression mood."
	# The anger clause only where anger is a live question: contact she refused, or a non-partner.
	# To a partner it read as "are you mad?" and she answered it (dev 2026-09-28: "Mad?! Why would I be mad!?").
	if not partner or entry.counts.has("kiss_refused"):
		text+=" You do not anger easily. If you really want him to stop, tell him; you can also use request_space. Save buck_player for lasting anger over unwanted contact."
	else:
		text+=" Nobody asked if you are upset, so there is no need to say that you are fine."
	return text


## The contact summary with the switch on: the touches as they happened, the anger clause chosen by
## what she has said they are (not by the old stage), and the contact note (design section 8).
func _bond_summary(text:String,runtime:Node,id:String,entry:Dictionary) -> String:
	var standing:Dictionary={}
	if runtime!=null and is_instance_valid(runtime.get("bonds")) and runtime.bonds.has_method("standing"):
		var got:Variant=runtime.bonds.standing(id)
		if got is Dictionary:standing=got
	var partner:bool=str(standing.get("status","none"))!="none"
	if not partner or entry.counts.has("kiss_refused"):
		text+=" You do not anger easily. If you really want him to stop, tell him; you can also use request_space. Save buck_player for lasting anger over unwanted contact."
	else:
		text+=" Nobody asked if you are upset, so there is no need to say that you are fine."
	var note:=BOND_PROMPT.contact_note(standing,entry.counts)
	return text if note.is_empty() else text+" "+note


## A contact turn has started for her with this turn id (contract section 4; C's contact_turn).
func _bond_turn(id:String) -> void:
	var kinds:Array=_turn_kinds.get(id,[])
	_turn_kinds.erase(id)
	if not BOND.DYNAMIC:return
	var runtime:Node=host.get_tree().get_first_node_in_group("player_relationships") if host.is_inside_tree() else null
	if runtime!=null and runtime.has_method("contact_turn"):runtime.contact_turn(id,host._turn_id,kinds)


## His batched touch was dropped without a turn: her press count ends (C's contact_dropped).
func _bond_dropped(id:String) -> void:
	_turn_kinds.erase(id)
	if not BOND.DYNAMIC:return
	var runtime:Node=host.get_tree().get_first_node_in_group("player_relationships") if host.is_inside_tree() else null
	if runtime!=null and runtime.has_method("contact_dropped"):runtime.contact_dropped(id)


## A batched contact reaction that ended before its turn began.
func _lost(kind:String,id:String) -> void:
	if kind=="contact":_bond_dropped(id)


## Every model answered a throw with "I'm a pony, not a sack of oats!" (dev 2026-10-26). Each throw
## now names one way to react, drawn at random, rules out that phrasing, and says how often he has
## thrown her lately so a third toss lands differently from the first.
const THROWN_ANGLES := ["a wordless yelp or gasp, nothing more", "laughing, maybe asking to go again",
	"scolding him by name", "flustered or embarrassed rather than angry", "a dry, deadpan remark",
	"checking her mane or coat is not ruined", "asking him what that was for", "playing it cool, as if nothing happened",
	"only [silence] and a look", "a short threat of payback, in fun or not"]

func _thrown_event(id: String) -> String:
	var entry: Dictionary = host.characters.get(id, {})
	var recent: Array = entry.get("thrown_at", []).filter(func(t): return host._now() - float(t) < 300.0)
	recent.append(host._now())
	if not entry.is_empty(): entry["thrown_at"] = recent
	var angle: String = THROWN_ANGLES[host._reaction_rng.randi_range(0, THROWN_ANGLES.size() - 1)]
	var times := "" if recent.size() < 2 else " He has now thrown you %d times in the last few minutes." % recent.size()
	return "Anon just threw you from his hands. Give a quick reaction in your own voice to being tossed, whether surprise, protest, or amusement, fitting your character and how you get along. Don't make up injuries or claim you've landed unless your situation confirms it." + times + " This time react as: " + angle + ", if that fits your character. Never compare yourself to an object, and never say you are a pony, a dragon or anything else that is \"not a\" sack, beanbag, ball or toy."
