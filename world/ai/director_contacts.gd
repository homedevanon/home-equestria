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

var host: Node
var _remembered_contacts:Dictionary={}


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
	if not host.characters.has(id):return
	if not is_instance_valid(host.player_head) or not is_instance_valid(host.characters[id].node):return
	if not host.awareness.can_hear(host.characters[id].node,host.player_head,host._earshot(id)):return
	if host.state!="idle" or host.speech.state=="hearing":
		if (kind in ["carried", "carried_away", "sprayed", "thrown", "snowball_hit"] or kind.begins_with("anon_resting")) and not deferred:
			host._pending_contacts[id] = {"kind": kind, "until": host._now() + 12.0}
		return
	if kind not in ["farewell","contact"] and host._reaction_rng.randf()>=reaction_chance(kind):return
	host._current=id;host._listener_id="player";host._turn_id+=1;host._rewrite_used=false;host._recorded=false
	# Conversation clock: a fresh chat starts after two quiet minutes; the situation block
	# suggests sitting or lying down once a chat has run a while (dev, 2026-09-16).
	if kind!="quiet" and kind!="farewell":
		if host._now()-float(host.characters[id].get("chat_last",-1e9))>120.0:host.characters[id]["chat_since"]=host._now()
		host.characters[id]["chat_last"]=host._now()
	host._pending_text="";host._pending_actions=[];host._player_text=""
	host._set_attention(id,host.player_head)
	host.state="thinking";host.speech.set_muted(false);host._show_indicator("thinking");host.hud.set_state("thinking","")
	var event:=summary
	if kind == "carried": event = "Anon has been holding you off the ground in his hands for over five seconds. You may simply enjoy being held in silence. If words add something, one or two can be enough. Do not invent where he intends to take you."
	if kind == "carried_away": event = "Anon picked you up and is moving away from where he lifted you, carrying you in his hands. You may enjoy the ride silently; speak only if something needs saying. You do not yet know his destination or intent."
	if kind.begins_with("carried") and CRADLE_REST.cradled(host.characters[id].node): event = CRADLE_REST.CARRIED_EVENT if kind == "carried" else CRADLE_REST.CARRIED_AWAY_EVENT
	if kind == "thrown": event = _thrown_event(id)
	# Cuddling is her choice (dev 2026-09-28): the bed or couch only tells her he is lying there.
	if kind.begins_with("anon_resting"): event = "Anon is lying down on the %s a few steps from you, resting. If you would like to cuddle with him, say so and use [cuddle]. It is just as fine to leave him be, or only say something." % kind.get_slice(":", 1)
	if kind == "sprayed": event = "Anon just sprayed you with plain water from a small spray bottle. Your coat is damp where it hit. React briefly in character to the water."
	if kind == "snowball_hit": event = "Anon just hit you with a snowball; snow is on your coat. React briefly in character: laugh, protest, or promise payback. You may throw one back if your actions allow it."
	if kind=="quiet":event="The player has been quiet since your last reply. Sometimes just relish the moment with them: comfortable silence is a complete answer, so reply with only [silence], above all if you already asked a question. Speak only with a reason: a few natural words, then wait; never continue a monologue, restart your last topic or invent a project from the scenery. You may bring up something new instead. " + preload("res://world/ai/chatter_topics.gd").seed_line()
	if kind=="farewell":
		event="The conversation has run its course: "+host._farewell_reason+" Decide for yourself what you do next. Usually you say a short goodbye in your own words and voice, then go about your day (go_to, go_home or resume_routine). You need not say where you are going or why. This is your choice, bedtime included: if you would rather stay with the player (a friend, a good talk, a moment worth staying up for), say so and use [stay] (or [follow: player] if he is walking somewhere). Speak; do not reply with only [silence]."
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
	if not await host._take_llm(): return
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
	host._contact_log.erase(id)
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
			host._contact_log.erase(id);continue
		if host._now()-float(entry.last)<CONTACT_PAUSE and host._now()-float(entry.first)<CONTACT_BATCH_MAX:continue
		# A kiss owns the moment; do not build a deferred contact monologue.
		if host.characters[id].node.has_meta("affection_active"):
			host._contact_log.erase(id);continue
		if host._now()<float(host._contact_next.get(id,0.0)) or host.state!="idle" or host.speech.state=="hearing":continue
		host._contact_log.erase(id)
		host._contact_next[id]=host._now()+CONTACT_COOLDOWN
		# Each touch is another chance to be noticed: a single boop often passes, a flurry does not.
		var unnoticed:=1.0
		for kind:String in entry.counts:
			unnoticed*=pow(1.0-reaction_chance(kind),float(entry.counts[kind]))
		if host._reaction_rng.randf()>=1.0-unnoticed:continue
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
		text+=" Boops tickle and make you giggle." if filly else " Secretly, nose boops feel wonderful to you: they leave you flustered, giddy and warm, even when you pretend to protest. A flurry of boops flusters you far more than it annoys you."
	if entry.counts.has("petted"):
		text+=" Being petted is affectionate and pleasant; you enjoy it unless you are truly, deeply upset with Anon."
	var runtime:Node=host.get_tree().get_first_node_in_group("player_relationships")
	var stage:=str(runtime.bonds.record_for(id).stage) if runtime!=null and is_instance_valid(runtime.bonds) else ""
	var partner:bool=stage in ["dating","engaged","married"]
	if partner and (entry.counts.has("kiss") or entry.counts.has("deep_kiss")):
		text+=" You are in love with Anon and his kisses are wanted: you want to kiss him too, and a flurry of kisses can leave you quietly melting. Sometimes just relish it in silence; a word or two can say more than a speech. Do not scold him for kissing you or ask for warnings. If you choose to kiss him yourself, use [kiss_player]; you may accompany it with a short spoken line."
	text+=" How you feel is yours to decide from your character and your relationship with Anon; show it in your words, face tag and impression mood."
	# The anger clause only where anger is a live question: contact she refused, or a non-partner.
	# To a partner it read as "are you mad?" and she answered it (dev 2026-09-28: "Mad?! Why would I be mad!?").
	if not partner or entry.counts.has("kiss_refused"):
		text+=" Real anger takes a lot. If you truly want him to stop, say so; request_space is available. buck_player is only for real, lasting anger at unwelcome contact."
	else:
		text+=" Nobody is asking whether you are upset; there is no need to say you are not."
	return text


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
	return "Anon just threw you from his hands. React briefly in your own voice to being tossed; surprise, protest or amusement should fit your character and relationship. Do not invent injuries or claim you have landed somewhere unless your current situation confirms it." + times + " This time react as: " + angle + ", if it fits your character. Never say you are a pony, dragon or anything else that is \"not a\" sack, beanbag, ball, toy or other object; do not compare yourself to an object at all."
