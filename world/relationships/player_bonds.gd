extends Node
## Authoritative player relationships. Dialogue can offer/answer; only observed events progress trust.
signal changed(id: String)
signal boundary(id: String, level: float, kind: String)
const STAGES := ["acquaintance", "friend", "close_friend", "dating", "engaged", "married"]
const KINDS := ["outing", "date", "dating", "move_in", "engagement", "marriage", "kiss", "hug", "flank_touch", "break_up"]
## "place": time together at a mapped place she names (a lake, a landmark; dev 2026-09-28).
const ACTIVITIES := ["walk", "fishing", "orchard", "meal", "visit", "place"]
const ROMANTIC := ["date", "dating", "move_in", "engagement", "marriage", "kiss", "flank_touch"]
## AnonPony (world/life/player_form.gd): a young player (filly or colt) is offered no romance by
## anypony, and a mare player is a pony's marefriend, not her coltfriend.
const PERSONALITY := preload("res://world/relationships/friendship_personality.gd")
const REST_POLICY := preload("res://world/relationships/shared_rest_policy.gd")
const PLAYER_FORM := preload("res://world/life/player_form.gd")
const ARRIVAL_CONTEXT := preload("res://world/ai/arrival_context.gd")
## Relationship overhaul 2026-11-19: love from game facts, her yes in her own words, casual and
## committed intimacy (romance_rules.gd, rollback switch RULES.FACTS).
const RULES := preload("res://world/relationships/romance_rules.gd")
const LADDER := preload("res://world/relationships/bond_ladder.gd")
var context: Node
var data: Dictionary = {"records": {}, "serial": 0, "seen": {}}
var adults: Dictionary = {}
var _staged: Dictionary = {}
## Session-only: when she last showed romance (a tag, a kiss, a warm reply), the last time each kind
## of love fact counted, and the "just now" moments her prompt names.
var _warm: Dictionary = {}
var _love_at: Dictionary = {}
var _moments: Dictionary = {}
var _fact_serial := 0

## Courtship (dev 2026-09-29: "the process of becoming officially marefriend and coltfriend
## triggered by the ai after sufficient time with rejection mechanics"). Time spent near her adds
## up (together_s). Once she could date him (eligible "dating"), is fond of him (romance 25+) and
## they have spent READY_TOGETHER_S together, her prompt tells her she wants to ask him to be her
## coltfriend, in her own words, when the moment is right. If he says no she is hurt (a romance
## dip, a sad mood), waits three game days, and after two refusals never asks again (he still
## can). If she says no to him, he has to wait a game day; asking again sooner annoys her.
const READY_TOGETHER_S := 3600.0
const REFUSED_WAIT_DAYS := 3.0
const TURNED_DOWN_WAIT_DAYS := 1.0
const ASKS := 2
var _together: Dictionary = {}

func add_together(id: String, seconds: float) -> void:
	if BOND.DYNAMIC:
		# Time in her company is a diary fact; written every half minute so a save is not made each second.
		if not adults.has(id) or context == null or context._read_only: return
		_together[id] = float(_together.get(id, 0.0)) + seconds
		if float(_together[id]) < 30.0: return
		var rt := record_for(id)
		rt["together_s"] = float(rt.get("together_s", 0.0)) + float(_together[id])
		_b(rt).company_s = float(_b(rt).company_s) + float(_together[id])
		_together[id] = 0.0
		_put(id, rt)
		return
	if not adults.get(id, false): return
	_together[id] = float(_together.get(id, 0.0)) + seconds
	if float(_together[id]) < 30.0: return
	var r := record_for(id)
	var before := float(r.get("together_s", 0.0))
	r["together_s"] = before + float(_together[id])
	_together[id] = 0.0
	_save(id, r)
	# Time near each other is part of falling for someone: one love point every TOGETHER_LOVE_S.
	if floorf(float(r.together_s) / RULES.TOGETHER_LOVE_S) > floorf(before / RULES.TOGETHER_LOVE_S): love_fact(id, "together")

func ready_to_ask(id: String) -> bool:
	if BOND.DYNAMIC: return adults.has(id) and not _young_player() and _wants_to_ask(record_for(id)) == "couple"
	var r := record_for(id)
	if not eligible(id, "dating") or int(r.get("asks_left", ASKS)) <= 0: return false
	if offer_on_cooldown(id, "dating"): return false
	return float(r.get("together_s", 0.0)) >= READY_TOGETHER_S and interest(id) >= 25

## Asked again while she still wants time: a little less trust, and she is annoyed.
func pestered(id: String) -> void:
	if BOND.DYNAMIC: return
	var r := record_for(id)
	r.trust = maxf(0.0, float(r.trust) - 2.0)
	_save(id, r)
	if context != null and is_instance_valid(context.impressions):
		context.impressions.commit(id, {"mood": "annoyed", "thought": "%s asked me again already. I told %s I need time." % [str(_player_words().subject).capitalize(), _player_words().object]}, "pester_%d" % Time.get_ticks_usec())

func bind(store: Node) -> void:
	if BOND.DYNAMIC:
		context = store
		data = store.state.get("player_bonds", {"records": {}, "serial": 0}).duplicate(true)
		if not data.has("seen"): data.seen = {}
		if not data.has("knowledge"):
			data.knowledge = {}
			var known_events: Array = store.state.get("events", []) if store.state.get("events") is Array else []
			data.knowledge_legacy = not data.records.is_empty() or not known_events.is_empty()
			if not store._read_only: store.state.player_bonds = data.duplicate(true)
		_staged.clear()
		_dynamic_bind()
		return
	context = store
	data = store.state.get("player_bonds", {"records": {}, "serial": 0}).duplicate(true)
	if not data.has("seen"): data.seen = {}
	# Who has actually met Anon, kept apart from the relationship stage (dev 2026-10-02 plan,
	# docs/plans/AI_CONTEXT_AND_INTERRUPTION_RESILIENCE_2026_10_02.md "First meetings"). A world
	# from before this record exists gets "unknown" for everypony without evidence, never a reset.
	if not data.has("knowledge"):
		data.knowledge = {}
		var events: Array = store.state.get("events", []) if store.state.get("events") is Array else []
		data.knowledge_legacy = not data.records.is_empty() or not events.is_empty()
		# Kept with the world from now on, so a later load tells a new world from an old one.
		if not store._read_only: store.state.player_bonds = data.duplicate(true)
	# Offers, permission and timed plans are session-local; loading never penalizes
	# someone for time spent outside the game or resurrects physical consent.
	for row: Dictionary in data.records.values():
		row.offer = {}; row.permissions = {}
		if not row.plan.is_empty(): row.plan.deadline = now() + plan_seconds()
	_staged.clear()

func register(id: String, adult: bool) -> void:
	adults[id] = adult

## Wall-clock seconds plus world time skipped by sleeping (time_of_day.gd skipped_seconds), so a
## cooldown or "again within 30 seconds" never spans a night's sleep.
func now() -> float:
	return Time.get_unix_time_from_system() + preload("res://autoload/time_of_day.gd").skipped()

func day() -> float:
	var clock := get_node_or_null("/root/TimeOfDay")
	return float(clock.day) + float(clock.hours) / 24.0 if clock != null else 0.0

## Her record as stored, for reading only: never change what it returns (record_for() hands out a
## copy to change and _save()). The once-a-second relationship step reads one or two fields of
## every pony's record; record_for() copied the whole record, experiences and promises and all,
## several times per pony each second (audit 2026-11-20).
const NO_RECORD := {}

func peek(id: String) -> Dictionary:
	var found: Variant = data.records.get(id)
	return found if found is Dictionary else NO_RECORD

func record_for(id: String) -> Dictionary:
	if BOND.DYNAMIC:
		var stored: Variant = data.records.get(id)
		if stored is Dictionary:
			var copy: Dictionary = (stored as Dictionary).duplicate(true)
			if not copy.get(BOND.SAVE_KEY) is Dictionary: copy[BOND.SAVE_KEY] = _convert(id, copy) if context != null else MEMORY.fresh("stranger", -1, 0.0)
			return copy
		var row := _old_record(id)
		row[BOND.SAVE_KEY] = _new_bond(id)
		# The old fields of a record not yet stored, as _echo() would write them.
		var known: Array = BOND.FIXED_KNOWN.get(str(row[BOND.SAVE_KEY].closeness), [0.0, 0.0])
		row.familiarity = float(known[0]); row.trust = float(known[1])
		return row
	return _old_record(id)

func _old_record(id: String) -> Dictionary:
	return data.records.get(id, {"stage":"acquaintance", "familiarity":0.0, "trust":0.0,
		"experiences":{}, "dates":0, "dating_since":-1.0, "engaged_since":-1.0,
		"shared_home_id":"", "offer":{}, "plan":{}, "permissions":{}, "cooldowns":{},
		"anger":0.0, "anger_at":0.0, "last_contact":0.0, "last_buck":0.0,
		"last_visit_day":-1, "last_met":0.0, "promises":[]}).duplicate(true)

## "met": completed speech, or the arrival's confirmed physical meeting receipt;
## "knows_name": she heard his name from him. A glance or touch is not an introduction.
## Familiarity under this is "has met him, hardly knows him": about five conversations
## (friendship_personality.gd gives 2 a conversation), fewer after shared activities.
const NEW_ACQUAINTANCE := 10.0

func knowledge(id: String) -> Dictionary:
	var known: Dictionary = (data.get("knowledge", {}) as Dictionary).get(id, {})
	var arrival: Dictionary = ARRIVAL_CONTEXT.meeting_for(context.state, id) if is_instance_valid(context) else {}
	if not arrival.is_empty() and not bool(known.get("met", false)):
		# Repair the view, not the save: meeting receipts grant neither name knowledge
		# nor familiarity, romance, or permission.
		var projected := known.duplicate()
		projected.erase("unknown")
		projected.merge(arrival, true)
		return projected
	if not known.is_empty(): return known
	if bool(data.get("knowledge_legacy", false)):
		# An older world: a record with shared experiences is evidence enough of a meeting.
		var r: Dictionary = data.records.get(id, {})
		if not r.is_empty() and (float(r.get("familiarity", 0.0)) > 0.0 or not (r.get("experiences", {}) as Dictionary).is_empty()):
			return {"met": true, "knows_name": true, "evidence": "earlier play"}
		return {"unknown": true}
	return {"met": false, "knows_name": false}

func mark_met(id: String) -> void:
	if BOND.DYNAMIC and context != null and not context._read_only and not id.is_empty():
		_know(id, "met")
		var rm := record_for(id)
		if str(_b(rm).closeness) == "stranger" or not data.records.has(id):
			_meet(_b(rm))
			_put(id, rm)
		return
	_know(id, "met")

## She heard him name his kind ("human"): from then on the word is hers to use.
func mark_kind_known(id: String) -> void:
	_know(id, "knows_kind")

## `told` is the name he gave her ("" keeps the configured one).
func mark_name_known(id: String, told := "") -> void:
	_know(id, "knows_name", told)

func _know(id: String, key: String, told := "") -> void:
	if context == null or context._read_only or id.is_empty(): return
	var all: Dictionary = data.get("knowledge", {})
	var known: Dictionary = (all.get(id, {}) as Dictionary).duplicate()
	if bool(known.get(key, false)) and (told.is_empty() or str(known.get("told_name", "")) == told): return
	known.erase("unknown")
	known[key] = true
	if not told.is_empty(): known.told_name = told.left(20)
	if key == "met" and not known.has("first_met"): known.first_met = now()
	all[id] = known
	data.knowledge = all
	context.state.player_bonds = data.duplicate(true)
	context._changed()

## One plain line for her prompt: first meeting, met, or unknown, and whether she knows his name.
func knowledge_line(id: String) -> String:
	var known := knowledge(id)
	var w := _player_words()
	var human := not PLAYER_FORM.is_pony(PLAYER_FORM.active(get_tree()) if is_inside_tree() else PLAYER_FORM.human())
	var told := str(known.get("told_name", ""))
	var name_line := (" %s told you %s name is %s; call %s that." % [w.subject.capitalize(), w.possessive, told, w.object] if not told.is_empty() and told.to_lower() != "anon" else "") if bool(known.get("knows_name", false)) else " You don't know %s name yet. \"Anon\" is just what these notes call %s, so never call %s Anon or any other name until %s gives you one." % [w.possessive, w.object, w.object, w.subject]
	if bool(known.get("unknown", false)):
		return "- Anon and you: you might have met before, or maybe not. Don't make up any past friendship or history." + name_line
	# What a human is called (dev 2026-11-13: ponies went along with Anon "as if I had lived there
	# my whole life"). The word is hers only once he has said it to her (mark_kind_known).
	var kind_line := ""
	if human:
		kind_line = " %s told you %s kind is called human, and that word is all you know about it." % [w.subject.capitalize(), w.possessive] if bool(known.get("knows_kind", false)) \
			else " You have no idea what %s kind is called. The word \"human\" is just for these notes, so don't say or think it until %s tells you." % [w.possessive, w.subject]
	if not bool(known.get("met", false)):
		if not human:
			return ("- Anon and you: this is your first meeting. %s is a pony you've never seen before, a stranger in town who knows nothing about you. Be as open or guarded as you are with any stranger, polite or curious in your own way without getting familiar. Don't use pet names or just go along with what %s asks as if you knew %s. You have no history together, so never claim to know %s already." % [w.subject.capitalize(), w.subject, w.object, w.object]) + name_line
		# After a couple of days word of him has gone round; seeing him is still new.
		var heard := " Town rumors mention a strange two-legged creature around, nothing more. Now %s is standing in front of you." % w.subject if _days_in_world() >= 3 else ""
		return ("- Anon and you: this is your first meeting, and no pony in Equestria has ever seen a creature like %s. Taller than a pony, %s stands upright on two legs, has no coat, wears clothes, and has hands with fingers. You don't know what %s is, where %s came from, why %s is here, or if %s is safe. Also, %s is a stranger who knows nothing of you, Ponyville, or pony ways.%s Let your natural reaction show first, whether you're startled, wary, shy, suspicious, fascinated, or openly curious. You might stare, hang back, or ask what %s is first. %s isn't a neighbor or friend, so avoid easy familiarity and pet names, and don't just go along with what %s asks as if you knew %s. You have no history together, so never claim to know %s already." % [
			w.object, w.subject, w.subject, w.subject, w.subject, w.subject, w.subject, heard, w.subject, w.subject.capitalize(), w.subject, w.object, w.object]) + kind_line + name_line
	if str(known.get("evidence", "")) == "arrival receipts" and not bool(known.get("spoken", false)):
		return "- Anon and you: you ran into each other in the Everfree and are still in the middle of your first conversation." + (" %s is the first of %s kind you've ever seen, and you still know almost nothing about %s." % [w.subject.capitalize(), w.possessive, w.object] if human else "") + kind_line + name_line
	# The first handful of talks: she has met him, she does not know him.
	var record: Dictionary = data.records.get(id, {})
	if str(record.get("stage", "acquaintance")) == "acquaintance" and float(record.get("familiarity", 0.0)) < NEW_ACQUAINTANCE:
		return ("- Anon and you: you've met and talked briefly before, so %s is still almost a stranger%s. All you know about %s is what %s told you or what you've seen. It's natural to feel curious, cautious, or awkward around %s, and closeness will take more meetings to build." % [
			w.subject, ", and still the strangest creature you have ever seen" if human else "", w.object, w.subject, w.object]) + kind_line + name_line
	return "- Anon and you: you have met and spoken before." + kind_line + name_line

## Whole days since this world began (time_of_day.gd first_day); 0 without the clock.
func _days_in_world() -> int:
	var clock := get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	return int(clock.call("day_number")) - 1 if clock != null and clock.has_method("day_number") else 0

func _save(id: String, row: Dictionary) -> void:
	if BOND.DYNAMIC:
		if context == null or context._read_only: return
		_dynamic_save(id, row)
		return
	if context == null or context._read_only: return
	data.records[id] = row.duplicate(true)
	context.state.player_bonds = data.duplicate(true)
	context._changed()
	changed.emit(id)

func interest(id: String) -> int:
	if BOND.DYNAMIC: return LADDER.unseed_romance(love_xp(id))
	return int(context.impressions.profile(id).love) if context != null and is_instance_valid(context.impressions) else 0

## Anger is the pony's own AI mood (dev 2026-09-28): a fresh angry/annoyed impression, which
## lapses after five minutes. Contact never adds scripted anger; old "anger" save fields are unused.
func anger(id: String) -> float:
	if context == null or not is_instance_valid(context.impressions): return 0.0
	match str(context.impressions.profile(id).mood):
		"angry": return 70.0
		"annoyed": return 40.0
	return 0.0

## False for a filly or colt pony and for a young player; unregistered ponies (tests) count as adults.
func eligible_for_romance(id: String) -> bool:
	return bool(adults.get(id, true)) and not _young_player()

func eligible(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return _dynamic_eligible(id, kind)
	if not adults.has(id) or kind not in KINDS: return false
	if kind in ROMANTIC and (not adults[id] or _young_player()): return false
	var r := record_for(id)
	var rank := STAGES.find(r.stage)
	if kind == "break_up": return rank >= 3
	if kind in ["date","outing"] and not r.plan.is_empty():return false
	if anger(id) >= 35.0: return false
	match kind:
		"outing", "hug": return true
		"date": return rank >= 1 and r.trust >= 15 and interest(id) >= 5
		# No completed date needed (dev 2026-10-31): friends with some trust can ask, and her AI decides.
		"dating": return rank in [1,2] and r.trust >= 20 and interest(id) >= 5
		"move_in": return rank >= 3 and r.trust >= 35
		"engagement": return rank == 3 and r.dates >= 3 and r.trust >= 50 and day() - r.dating_since >= 3.0
		"marriage": return rank == 4 and day() - r.engaged_since >= 1.0
		"kiss", "flank_touch": return rank >= 3
	return false

## Her own yes (RULES.FACTS; dev 2026-11-15: "It shouldn't be hard-locked ... Some relationships
## happen quickly"). eligible() above still decides what she may PROPOSE herself (her offer list);
## a step she chooses to ACCEPT, or Anon's ask that she gets to answer, is held only to structure and
## age: an adult on both sides, steps in order (engaged while dating, married once engaged, a shared
## home with a partner), one open outing at a time. Mood, trust and love scores no longer refuse it.
func agreeable(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return _dynamic_agreeable(id, kind)
	if not RULES.FACTS: return eligible(id, kind)
	if not adults.has(id) or kind not in KINDS: return false
	if kind in ROMANTIC and (not adults[id] or _young_player()): return false
	var r := record_for(id)
	var rank := STAGES.find(r.stage)
	match kind:
		"outing", "date": return r.plan.is_empty()
		"hug", "kiss", "flank_touch": return true
		"dating": return rank < 3
		"move_in", "break_up": return rank >= 3
		"engagement": return rank == 3
		"marriage": return rank == 4
	return false

## The steps her AI may say yes to right now (pony_action_schema.gd checks [agreed] against these).
func agreeable_kinds(id: String) -> Array:
	return KINDS.filter(func(kind: String) -> bool: return agreeable(id, kind))

func plan_seconds() -> float:
	return RULES.PLAN_SECONDS if RULES.FACTS else 900.0

func available(id: String) -> Array:
	return KINDS.filter(func(kind: String) -> bool: return eligible(id, kind))

func pending(id: String) -> Dictionary:
	if BOND.DYNAMIC: return _dynamic_pending(id)
	var offer: Dictionary = record_for(id).offer
	return offer if not offer.is_empty() and float(offer.expires) > now() else {}

## Game-day refusal waits survive sleeping and configurable day lengths. Older wall-clock
## cooldowns remain readable until they expire; brief accepted-offer cooldowns still use them.
func offer_on_cooldown(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return false
	var cooldowns: Dictionary = record_for(id).cooldowns
	return now() < float(cooldowns.get("offer:" + kind, 0.0)) or (kind == "dating" and day() < float(cooldowns.get("dating_day", -1.0)))

func offer(id: String, kind: String, by: String, activity := "walk", home := "", place := "") -> String:
	if BOND.DYNAMIC: return _dynamic_offer(id, kind, by, activity, home, place)
	if context._read_only or by not in ["player", "pony"] or not agreeable(id, kind): return ""
	if activity not in ACTIVITIES or (activity == "place" and place.is_empty()): return ""
	if not pending(id).is_empty(): return ""
	if kind in ["date","outing"] and not record_for(id).plan.is_empty():return ""
	if kind == "move_in" and home.is_empty(): return ""
	var r := record_for(id)
	if offer_on_cooldown(id, kind): return ""
	if kind == "dating" and by == "pony" and int(r.get("asks_left", ASKS)) <= 0: return ""
	data.serial = int(data.serial) + 1
	var key := "bond_%d" % int(data.serial)
	r.offer = {"id":key, "kind":kind, "by":by, "activity":activity, "home":home, "place":place, "expires":now()+180.0}
	_save(id, r)
	return key

func answer(id: String, key: String, by: String, accept: bool) -> bool:
	if BOND.DYNAMIC: return _dynamic_answer(id, key, by, accept)
	if context._read_only: return false
	var p := pending(id)
	if p.is_empty() or p.id != key or p.by == by or by not in ["player", "pony"]: return false
	if accept and not agreeable(id, p.kind): return false
	var r := record_for(id)
	r.offer = {}
	r.cooldowns["offer:" + p.kind] = now() + (60.0 if accept else 300.0)
	if accept:
		var invite: bool = RULES.FACTS and p.kind in ["kiss", "hug"]
		match p.kind:
			"outing", "date":
				r.plan = {"id":p.id, "activity":p.activity, "place":str(p.get("place","")), "date":p.kind=="date", "accepted_at":now(), "deadline":now()+plan_seconds()}
				r.promises.append({"id":p.id,"activity":p.activity,"status":"pending"})
				while r.promises.size() > 16: r.promises.pop_front()
			"dating": r.stage = "dating"; r.dating_since = day()
			"move_in": r.shared_home_id = p.home
			"engagement": r.stage = "engaged"; r.engaged_since = day()
			"marriage": r.stage = "married"
			"kiss", "hug", "flank_touch": r.permissions[p.kind] = {"until":now()+(RULES.KISS_INVITE_SECONDS if invite else 120.0),"uses":4 if p.kind=="flank_touch" else (RULES.KISS_INVITE_USES if invite else 1)}
			"break_up":
				r.stage = "close_friend"; r.shared_home_id = ""; r.permissions = {}; r.plan = {}
	elif p.kind == "dating":
		if p.by == "pony":
			# He turned her down: it hurts, she waits, and she only asks so many times.
			r.cooldowns["offer:dating"] = 0.0
			r.cooldowns["dating_day"] = day() + REFUSED_WAIT_DAYS
			r["asks_left"] = maxi(0, int(r.get("asks_left", ASKS)) - 1)
			if is_instance_valid(context.impressions):
				var words := _player_words()
				context.impressions.commit(id, {"romance": -2, "mood": "sad", "thought": "I asked Anon to be my %s and %s said no. It hurts, so I'll give %s space." % [words.partner, words.subject, words.object]}, "refused_" + str(p.id))
		else:
			r.cooldowns["offer:dating"] = 0.0
			r.cooldowns["dating_day"] = day() + TURNED_DOWN_WAIT_DAYS
	_save(id, r)
	context.record("relationship", "You and Anon %s the %s invitation%s." % ["both accepted" if accept else "did not agree to", p.kind.replace("_"," "), " ("+p.activity+")" if p.kind in ["date","outing"] else ""], [id,"player"], [id,"player"])
	if accept and p.kind in ["dating", "engagement", "marriage", "move_in", "date"]:
		moment(id, {"dating": "you two became a couple", "engagement": "you got engaged", "marriage": "you got married", "move_in": "you agreed to live together", "date": "you agreed to go on a date"}[p.kind])
	return true

## Her AI heard Anon ask for this step in his own words (or say yes to her offer) and agreed
## ([agreed: KIND], dev 2026-10-31: "the game is supposed to be AI DIRECTED"). Eligibility still
## applies; an earlier refusal's wait does not, because she is the one saying yes now.
func agree(id: String, kind: String, home := "") -> bool:
	if BOND.DYNAMIC:
		var new_kind := str(NEW_KIND.get(kind, kind))
		if new_kind == "engaged" and _status(record_for(id)) == "engaged": new_kind = "married"
		if new_kind not in BOND.KINDS: return false
		return bool(step(id, new_kind, "yes", {"source": "api", "he_spoke": true, "home": home}).ok)
	# "[agreed: marry]" reads as engagement; once engaged the same yes is the wedding.
	if RULES.FACTS and kind == "engagement" and str(record_for(id).stage) == "engaged": kind = "marriage"
	if context._read_only or not agreeable(id, kind): return false
	var p := pending(id)
	if not p.is_empty():
		if str(p.kind) != kind: return false
		return answer(id, str(p.id), "pony" if p.by == "player" else "player", true)
	var r := record_for(id)
	r.cooldowns.erase("offer:" + kind)
	if kind == "dating": r.cooldowns.erase("dating_day")
	_save(id, r)
	var key := offer(id, kind, "player", "walk", home)
	return not key.is_empty() and answer(id, key, "pony", true)

func request_space(id: String) -> bool:
	if BOND.DYNAMIC:
		if context == null or context._read_only or not adults.has(id): return false
		var rs := record_for(id)
		_b(rs).kiss_word = "closed"; _b(rs).kiss_closed_by = "space"
		rs.permissions = {}
		_put(id, rs)
		context.record("relationship", "You asked Anon for space; physical affection is unwelcome until you say otherwise.", [id, "player"], [id, "player"])
		return true
	if context._read_only or not adults.has(id):return false
	var row:=record_for(id)
	row.permissions={};row.cooldowns.boundary=now()+180.0
	_save(id,row)
	context.record("relationship","You asked Anon for space; physical affection is currently unwelcome.",[id,"player"],[id,"player"])
	return true

func break_up(id: String) -> bool:
	if BOND.DYNAMIC:
		if context == null or context._read_only: return false
		var rb := record_for(id)
		if _status(rb) == "none": return false
		_end(rb)
		_put(id, rb)
		context.record("relationship", "Your romantic relationship with Anon ended. Do not assume continued romantic permission.", [id, "player"], [id, "player"])
		return true
	if context._read_only or not eligible(id,"break_up"):return false
	var r:=record_for(id)
	r.stage="close_friend";r.shared_home_id="";r.permissions={};r.plan={};r.offer={}
	_save(id,r)
	context.record("relationship","Your romantic relationship with Anon ended. Do not assume continued romantic permission.",[id,"player"],[id,"player"])
	return true

## For a future physical nap invitation: this reports existing closeness, never grants it.
func rest_closeness(id: String) -> String:
	if BOND.DYNAMIC:
		if not adults.get(id, false) or context == null: return "none"
		var rr := record_for(id)
		var stage_for := str(rr.stage) if _committed(rr) and not _young_player() else _plain_stage(str(_b(rr).closeness))
		var closed := str(_b(rr).kiss_word) == "closed" and str(_b(rr).kiss_closed_by) in ["space", "cold"]
		return REST_POLICY.closeness(stage_for, welcomes(id, "hug"), closed)
	if not adults.get(id, false) or context == null: return "none"
	var row: Dictionary = record_for(id)
	var blocked: bool = anger(id) >= 35.0 or now() < float(row.cooldowns.get("boundary", 0.0)) or (_young_player() and str(row.stage) in ["dating", "engaged", "married"])
	return REST_POLICY.closeness(str(row.stage), welcomes(id, "hug"), blocked)

func permitted(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return welcomes(id, kind)
	var permission: Dictionary = record_for(id).permissions.get(kind, {})
	return agreeable(id, kind) and float(permission.get("until",0.0)) > now() and int(permission.get("uses",0)) > 0

func consume_permission(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return welcomes(id, kind)
	if not permitted(id, kind): return false
	var r := record_for(id)
	r.permissions[kind].uses -= 1
	_save(id, r)
	return true

## Grey, not strict (dev 2026-09-28: "the boundaries are too strict, it's unrealistic; she LOVES
## me, she WANTS to kiss"). A partner (dating or further) welcomes kisses and playful smacks unless
## she is angry at him or asked for space; a mare who is attracted to Anon (romance 25+) and
## trusts him a little may welcome them too, unless annoyed. Hugs: friends, or anyone fond of him.
func welcomes(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return bool(adults.get(id, false)) and stance(id, kind) == "yes"
	if not adults.get(id, false): return false
	if kind in ROMANTIC and _young_player(): return false
	var r := record_for(id)
	if now() < float(r.cooldowns.get("boundary", 0.0)): return false
	var mood := str(context.impressions.profile(id).mood) if is_instance_valid(context.impressions) else "neutral"
	if mood == "angry": return false
	if permitted(id, kind): return true
	var partner := STAGES.find(r.stage) >= 3
	var fond: bool = interest(id) >= 25 and float(r.trust) >= 10.0
	if kind == "hug": return partner or fond or STAGES.find(r.stage) >= 1 or r.trust >= 10.0
	if partner: return true
	if mood == "annoyed": return false
	if fond or not RULES.FACTS: return fond
	# Her own signals, not a meter (thread 2026-11-15: she asked for the kiss, then turned away): she
	# just showed romance (a romance tag, her own kiss, her spoken invitation covers via permitted()),
	# or she has a crush on him that nothing he did has soured.
	if now() - float(_warm.get(id, -1e12)) < RULES.WARM_SECONDS: return true
	return love_xp(id) >= int(LADDER.LOVE_XP.crush) and not wary(id)

## Love XP she has for Anon (pony_impressions.gd xp_for; bond_ladder.gd levels).
func love_xp(id: String) -> int:
	if BOND.DYNAMIC: return _love_xp_of(record_for(id))
	return int(context.impressions.xp_for(id).romance) if context != null and is_instance_valid(context.impressions) else 0

## She holds a grudge, or has heard bad town talk about him (pony_impressions.gd M-AI-15).
func wary(id: String) -> bool:
	if BOND.DYNAMIC: return not (_b(record_for(id)).sore as Array).is_empty() or not _heard(id).is_empty()
	if context == null or not is_instance_valid(context.impressions) or not context.impressions.has_method("grudge"): return false
	var impressions: Node = context.impressions
	return impressions.grudge(id) >= float(impressions.GRUDGE.prompt_at) or not str(impressions.heard_about(id)).is_empty()

## Hard stops for a kiss she starts herself (relationship_runtime.can_kiss_player): a minor
## either side, her "space" cooldown or anger. Stage is not one: it only discourages (dev 2026-10-29).
func kiss_barred(id: String) -> bool:
	# Her own kiss is hers: only age bars it (design 8, "her own touch comes first").
	if BOND.DYNAMIC: return not adults.get(id, false) or _young_player()
	if not adults.get(id, false) or _young_player(): return true
	if now() < float(record_for(id).cooldowns.get("boundary", 0.0)): return true
	return is_instance_valid(context.impressions) and str(context.impressions.profile(id).mood) == "angry"

func contact(id: String, kind: String) -> bool:
	if BOND.DYNAMIC: return _dynamic_contact(id, kind)
	var r := record_for(id)
	# Repetition no longer turns welcome affection unwelcome: kissing her again and again is the
	# point of being together. Only a rapid flurry of smacks from a non-partner counts against it.
	var frequent: bool = kind == "flank_touch" and STAGES.find(r.stage) < 3 and now() - float(r.cooldowns.get("contact:"+kind, -1000.0)) < 4.0
	var accepted := welcomes(id, kind) and not frequent
	if permitted(id,kind) and accepted: r.permissions[kind].uses -= 1
	r.cooldowns["contact:"+kind] = now()
	_save(id,r)
	if not accepted: unwanted_contact(id,"flank_smack" if kind=="flank_touch" else kind)
	return accepted

func experience(id: String, kind: String, event_id: String) -> bool:
	if BOND.DYNAMIC: return _dynamic_experience(id, kind, event_id)
	if context._read_only or not adults.has(id) or kind not in ACTIVITIES + ["conversation", "gift"]: return false
	var r := record_for(id)
	if event_id.is_empty() or data.seen.has(id+":"+event_id): return false
	var plan: Dictionary = r.plan
	# The agreed plan is kept by doing it, even when the same kind of activity a few minutes earlier
	# put its friendship gain on cooldown (a meal date right after a snack was "missed"). Food fed to
	# her by hand counts for a meal date (thread 2026-11-19: feeding her was the one way that worked).
	var completes: bool = not plan.is_empty() and float(plan.deadline) >= now() and (plan.activity == kind \
		or (RULES.FACTS and kind == "gift" and plan.activity == "meal" and event_id.begins_with("fed_")))
	var cooling := now() < float(r.cooldowns.get(kind,0.0))
	if cooling and not (RULES.FACTS and completes): return false
	data.seen[id+":"+event_id] = true
	while data.seen.size() > 512: data.seen.erase(data.seen.keys()[0])
	if not cooling:
		r.cooldowns[kind] = now() + (120.0 if kind=="conversation" else 600.0)
		var gains: Dictionary = PERSONALITY.gains(id, kind, int(r.experiences.get(kind, 0)))
		r.experiences[kind] = int(r.experiences.get(kind,0)) + 1
		r.familiarity = minf(100.0, r.familiarity + float(gains.familiarity))
		r.trust = minf(100.0, r.trust + float(gains.trust))
		r.last_met = now()
		if r.stage in ["acquaintance","friend","close_friend"]:
			r.stage = "close_friend" if r.familiarity >= 60 and r.trust >= 30 and r.experiences.size() >= 3 else ("friend" if r.familiarity >= 20 and r.trust >= 10 else "acquaintance")
	if completes:
		if plan.date: r.dates += 1
		r.trust = minf(100.0, r.trust + PERSONALITY.kept_plan_trust(id))
		for promise: Dictionary in r.promises:
			if promise.id == plan.id: promise.status = "kept"
		r.plan = {}
	_save(id, r)
	context.record("shared_player_activity", "You and Anon completed %s together%s." % [kind, " on your agreed date" if completes and plan.get("date",false) else ""], [id,"player"], [id,"player"], "bond-"+event_id)
	if RULES.FACTS:
		if completes:
			moment(id, "you kept your date with him" if plan.get("date", false) else "you two did your planned outing together")
			if plan.get("date", false): love_fact(id, "date")
		if not cooling and kind != "conversation": love_fact(id, "gift" if kind == "gift" else "activity")
	return true

## They are together on their agreed plan: it stays open at least `seconds` more.
func extend_plan(id: String, seconds: float) -> void:
	if context == null or context._read_only: return
	var r := record_for(id)
	if r.plan.is_empty() or float(r.plan.deadline) >= now() + seconds: return
	r.plan.deadline = now() + seconds
	_save(id, r)

func cancel_plan(id: String) -> void:
	if context == null or context._read_only: return
	var r := record_for(id)
	if r.plan.is_empty(): return
	for promise: Dictionary in r.promises:
		if promise.id == r.plan.id: promise.status = "cancelled"
	r.plan = {}
	_save(id, r)
	context.record("cancelled_plan", "The walk ended after Anon left walking range.", [id,"player"], [id,"player"])

func expire_plan(id: String) -> void:
	# A plan has no time limit: it is kept, called off, or missed by his going to sleep on it.
	if BOND.DYNAMIC: return
	var seen: Variant = peek(id).get("plan")
	if not seen is Dictionary or (seen as Dictionary).is_empty(): return
	var r := record_for(id)
	if r.plan.is_empty() or float(r.plan.deadline) > now(): return
	for promise: Dictionary in r.promises:
		if promise.id == r.plan.id: promise.status = "missed"
	r.trust = maxf(0.0,r.trust-3.0)
	r.plan = {}
	_save(id,r)
	context.record("missed_plan", "Your agreed outing with Anon did not happen in time. You do not know why.",[id,"player"],[id,"player"])
	moment(id, "your agreed outing with him did not happen")

## Agreed meetings (world/life/appointments/appointments.gd). Standing her up costs trust like a
## missed outing; keeping one earns a kept plan's trust. Each meeting counts once; the promise list
## records it as a "place" promise. Appointments records the world event itself.
func stood_up(id: String, appointment_id: String) -> void:
	if BOND.DYNAMIC:
		_dynamic_appointment(id, appointment_id, false)
		return
	_appointment_promise(id, appointment_id, "missed", -3.0)

func kept_appointment(id: String, appointment_id: String) -> void:
	if BOND.DYNAMIC:
		_dynamic_appointment(id, appointment_id, true)
		return
	_appointment_promise(id, appointment_id, "kept", PERSONALITY.kept_plan_trust(id))

func _appointment_promise(id: String, appointment_id: String, status: String, trust: float) -> void:
	if context == null or context._read_only or id.is_empty() or appointment_id.is_empty(): return
	var key := id + ":appt:" + appointment_id
	if data.seen.has(key): return
	data.seen[key] = true
	while data.seen.size() > 512: data.seen.erase(data.seen.keys()[0])
	var r := record_for(id)
	r.trust = clampf(float(r.trust) + trust, 0.0, 100.0)
	if status == "kept": r.last_met = now()
	r.promises.append({"id": appointment_id, "activity": "place", "status": status})
	while r.promises.size() > 16: r.promises.pop_front()
	_save(id, r)
	if RULES.FACTS:
		moment(id, "he came to meet you as you two agreed" if status == "kept" else "he did not come to the meeting you agreed")
		if status == "kept": love_fact(id, "activity")

## Bucking is a last resort (dev 2026-09-28): the first refused kiss or smack gets only her
## reaction; doing it again within half a minute of being refused is what earns the buck.
func refused_again(id: String, kind: String) -> bool:
	if BOND.DYNAMIC:
		# Counts presses of her body's reflex (design 8), never seconds.
		var presses := int((_b(record_for(id)).presses as Dictionary).get(kind, 0))
		if kind == "kiss": return presses >= BOND.PRESS_BUCK
		if kind == "flank_touch": return presses >= BOND.PRESS_HINT
		return false
	var r := record_for(id)
	var key := "refused:" + kind
	var again := now() - float(r.cooldowns.get(key, -1000.0)) < 30.0
	r.cooldowns[key] = now()
	_save(id, r)
	return again

## Unwelcome contact costs a little trust. How she feels about it is her AI reaction's call.
func unwanted_contact(id: String, kind: String) -> float:
	if BOND.DYNAMIC:
		if context == null or context._read_only or not adults.has(id): return 0.0
		boundary.emit(id, anger(id), kind)
		return anger(id)
	if context._read_only or not adults.has(id): return 0.0
	var r := record_for(id)
	r.last_contact = now()
	r.trust = maxf(0.0,r.trust-2.0)
	_save(id,r)
	boundary.emit(id,anger(id),kind)
	return anger(id)

# --- Relationship overhaul 2026-11-19 (romance_rules.gd) ---------------------------------------

## A love point from something that actually happened (RULES.LOVE), so a model that forgets its
## [romance] tag no longer stalls her. It goes through pony_impressions.gd commit: nothing before
## Friend, the per-sitting budget, the per-day limit and the relationship pace all still apply, and
## the profile's change list names `why`. False when it was not even tried (gap, no romance, off).
func love_fact(id: String, why: String) -> bool:
	if BOND.DYNAMIC: return false
	if not RULES.FACTS or context == null or context._read_only or not is_instance_valid(context.impressions): return false
	if not bool(adults.get(id, false)) or not eligible_for_romance(id): return false
	var row: Array = RULES.LOVE.get(why, [1, 0.0])
	var key := id + ":" + why + (":%d" % int(floorf(day() / RULES.GIFT_DAYS)) if why == "gift" else "")
	if why == "gift" and _love_at.has(key): return false
	if float(row[1]) > 0.0 and now() - float(_love_at.get(key, -1e12)) < float(row[1]): return false
	_love_at[key] = now()
	if why in ["kiss", "her_kiss", "romantic_talk", "intimacy"]: note_warm(id)
	_fact_serial += 1
	context.impressions.commit(id, {"romance": int(row[0]), "why": why}, "fact:%s:%s:%d:%d" % [why, id, Time.get_ticks_msec(), _fact_serial])
	return true

## She just showed romance toward Anon (a romance tag, a kiss, a warm reply to his flirting): for
## RULES.WARM_SECONDS a kiss from him is welcome (welcomes()).
func note_warm(id: String) -> void:
	_warm[id] = now()

## Her spoken kiss invitation ("kiss me", relationship_runtime.gd reads her finished line): his
## next kisses are welcome for a while, as an accepted kiss offer is.
func invite_kiss(id: String) -> bool:
	if BOND.DYNAMIC: return false
	if not RULES.FACTS or context == null or context._read_only or not agreeable(id, "kiss"): return false
	var r := record_for(id)
	r.permissions["kiss"] = {"until": now() + RULES.KISS_INVITE_SECONDS, "uses": RULES.KISS_INVITE_USES}
	_save(id, r)
	note_warm(id)
	return true

## Something that just happened between them, for her next prompt ("Just now between you: ...").
## Session-only: older moments are her memories (world events) already.
func moment(id: String, text: String) -> void:
	if BOND.DYNAMIC: return
	if not RULES.FACTS or id.is_empty(): return
	var rows: Array = _moments.get(id, [])
	rows.append({"t": now(), "text": text})
	while rows.size() > RULES.MOMENTS * 2: rows.pop_front()
	_moments[id] = rows

func moments_line(id: String) -> String:
	if BOND.DYNAMIC: return ""
	var said := PackedStringArray()
	for row: Dictionary in _moments.get(id, []):
		if now() - float(row.t) < RULES.MOMENT_SECONDS: said.append(str(row.text))
	if said.is_empty(): return ""
	return "Just now between you: " + "; ".join(said.slice(maxi(0, said.size() - RULES.MOMENTS))) + "."

## A kiss happened (pony_affection.gd: her own [kiss_player], or his kiss she returned). It counts:
## a memory, a warm moment, love, and casual or committed intimacy with its consequences.
func kissed(id: String, by_her: bool) -> void:
	if BOND.DYNAMIC:
		if context == null or context._read_only or not bool(adults.get(id, false)) or _young_player(): return
		var rk := record_for(id)
		var bk := _b(rk)
		rk["kisses"] = int(rk.get("kisses", 0)) + 1
		MEMORY.add(bk, "kisses")
		if by_her: MEMORY.add(bk, "her_kisses")
		bk.kiss_word = "open"; bk.kiss_closed_by = ""
		_happened(bk, "her_kiss" if by_her else "kiss_returned", {}, true)
		_sort_act(id, rk, "kiss")
		_put(id, rk)
		if by_her: context.record("affection", "You kissed Anon.", [id, "player"], [id, "player"])
		_betray_partners(id)
		return
	if not RULES.FACTS or context == null or context._read_only or not bool(adults.get(id, false)) or _young_player(): return
	var r := record_for(id)
	r["kisses"] = int(r.get("kisses", 0)) + 1
	_save(id, r)
	note_warm(id)
	if by_her: context.record("affection", "You kissed Anon.", [id, "player"], [id, "player"])
	moment(id, "you kissed him" if by_her else "he kissed you and you kissed him back")
	love_fact(id, "her_kiss" if by_her else "kiss")
	_intimate(id, "kiss")

## For adult mods (the base game has no explicit content): intimacy between Anon and her happened.
## With a partner it deepens love; when they are not a couple it is casual: no love from it, "rushed"
## before she has a crush, town talk once he has flings with several mares in a week, and a partner
## of his finds out. Returns bond_state(id) afterwards.
func note_intimacy(id: String, kind := "intimacy") -> Dictionary:
	if BOND.DYNAMIC:
		if context != null and not context._read_only and bool(adults.get(id, false)) and not _young_player():
			var ri := record_for(id)
			if str(_b(ri).act_from) == "record":
				# The same act the mod's record already counted.
				_b(ri).act_from = ""
				_put(id, ri)
			else:
				_b(ri).act_from = "call"
				_act(id, ri, kind.left(24))
		return bond_state(id)
	if RULES.FACTS and context != null and not context._read_only and bool(adults.get(id, false)) and not _young_player():
		if STAGES.find(str(record_for(id).stage)) >= 3: love_fact(id, "intimacy")
		note_warm(id)
		moment(id, "you were intimate with him")
		_intimate(id, kind.left(24))
	return bond_state(id)

## Casual (not a couple) or committed (dating or further) intimacy, a kiss included.
func _intimate(id: String, kind: String) -> void:
	var r := record_for(id)
	var committed := STAGES.find(str(r.stage)) >= 3
	if committed:
		r["close"] = int(r.get("close", 0)) + 1
	else:
		r["casual"] = int(r.get("casual", 0)) + 1
		if kind != "kiss" and love_xp(id) < int(LADDER.LOVE_XP.crush): r["rushed"] = int(r.get("rushed", 0)) + 1
	# Flings are intimacy beyond a kiss: three kisses in a week is no town scandal (a kiss still counts
	# as casual above, and as cheating below when he has a partner).
	if not committed and kind != "kiss":
		var flings: Dictionary = (data.get("flings", {}) as Dictionary).duplicate()
		flings[id] = day()
		for other: String in flings.keys():
			if day() - float(flings[other]) > RULES.FLING_DAYS: flings.erase(other)
		data["flings"] = flings
		if flings.size() >= RULES.FLING_TALK and is_instance_valid(context.impressions) and context.impressions.has_method("note_deed"):
			var key := "fling:%s:%d" % [id, int(day())]
			if not data.seen.has(key):
				data.seen[key] = true
				context.impressions.note_deed(id, "fling", 1.0)
	_save(id, r)
	if not committed: _cheat(id)

## He is with another mare (dating or further) and was intimate with `id`: town talk names it, and
## his partner either sees it (near enough) or hears about it a game day later.
func _cheat(id: String) -> void:
	if not is_instance_valid(context.impressions): return
	var w := _player_words()
	for other: String in data.records.keys():
		if other == id or STAGES.find(str((data.records[other] as Dictionary).get("stage", ""))) < 3: continue
		var key := "cheat:%s:%s:%d" % [other, id, int(day())]
		if data.seen.has(key): continue
		data.seen[key] = true
		if context.impressions.has_method("note_deed"): context.impressions.note_deed(other, "cheat", 2.0)
		var with_name := _name(id)
		if _near(other, id, 20.0):
			context.impressions.commit(other, {"friendship": -3, "romance": -2, "mood": "sad", "why": "saw him with another mare",
				"thought": "I saw Anon with %s. %s is supposed to be with me." % [with_name, str(w.subject).capitalize()]}, key)
			moment(other, "you saw him being intimate with %s" % with_name)
		else:
			var row := record_for(other)
			row["betrayed"] = {"with": with_name, "day": day() + 1.0}
			_save(other, row)

func _relationships() -> Node:
	return get_tree().get_first_node_in_group("player_relationships") if is_inside_tree() else null

func _near(a: String, b: String, metres: float) -> bool:
	var runtime := _relationships()
	if runtime == null: return false
	var first: Variant = runtime.actors.get(a)
	var second: Variant = runtime.actors.get(b)
	return is_instance_valid(first) and is_instance_valid(second) and (first as Node3D).global_position.distance_to((second as Node3D).global_position) <= metres

func _name(id: String) -> String:
	var runtime := _relationships()
	var actor: Variant = runtime.actors.get(id) if runtime != null else null
	var identity: Variant = (actor as Node).get("identity") if is_instance_valid(actor) else null
	return str(identity.get("display_name")) if identity != null and identity.get("display_name") != null else id.replace("_", " ").capitalize()

## 0..1, how deep her bond with Anon runs, for mods that make a moment better with love: up to 0.4
## for a fling (by love toward New Couple), 0.4 to 1.0 for a partner (by love toward Soulmates).
func devotion(id: String) -> float:
	if BOND.DYNAMIC: return _dynamic_devotion(id)
	var xp := float(love_xp(id))
	if STAGES.find(str(record_for(id).stage)) >= 3:
		return 0.4 + 0.6 * clampf(xp / float(LADDER.LOVE_XP.soulmates), 0.0, 1.0)
	return 0.4 * clampf(xp / float(LADDER.LOVE_XP.partner), 0.0, 1.0)

## Stable read API for mods (version 1; keys are only ever added, never renamed). record_for(id).stage
## and welcomes(id, "kiss"), which bundled mods already read, keep working as before.
##   stage, committed, romance_allowed, love_level (-1 none, 0 Crush .. 4 Soulmates), love_name,
##   love_xp, friend_level, friend_name, trust, familiarity, devotion (0..1), welcomes_kiss, wary,
##   mood, kisses, casual, committed_intimacy, rushed, partner_elsewhere, flings_this_week.
func bond_state(id: String) -> Dictionary:
	if BOND.DYNAMIC: return _dynamic_state(id)
	var r := record_for(id)
	var rank := STAGES.find(str(r.stage))
	var runtime := _relationships()
	var levels: Dictionary = runtime.ladder(id) if runtime != null and runtime.has_method("ladder") else {}
	var love: Dictionary = levels.get("love", {})
	var friend: Dictionary = levels.get("friendship", {})
	var partner_elsewhere := false
	for other: String in data.records.keys():
		if other != id and STAGES.find(str((data.records[other] as Dictionary).get("stage", ""))) >= 3: partner_elsewhere = true
	return {"version": 1, "stage": str(r.stage), "committed": rank >= 3,
		"romance_allowed": bool(adults.get(id, false)) and eligible_for_romance(id),
		"love_level": int(love.get("level", -1)), "love_name": str(love.get("name", "")), "love_xp": love_xp(id),
		"friend_level": int(friend.get("level", 0)), "friend_name": str(friend.get("name", "")),
		"trust": float(r.trust), "familiarity": float(r.familiarity), "devotion": devotion(id),
		"welcomes_kiss": welcomes(id, "kiss"), "wary": wary(id),
		"mood": str(context.impressions.profile(id).mood) if context != null and is_instance_valid(context.impressions) else "neutral",
		"kisses": int(r.get("kisses", 0)), "casual": int(r.get("casual", 0)), "committed_intimacy": int(r.get("close", 0)),
		"rushed": int(r.get("rushed", 0)), "partner_elsewhere": partner_elsewhere,
		"flings_this_week": (data.get("flings", {}) as Dictionary).values().filter(func(at: Variant) -> bool: return day() - float(at) <= RULES.FLING_DAYS).size()}

## Counts in plain words for her prompt ("talks 28, walks 2; promises kept 1, missed 1").
static func _shared_words(r: Dictionary) -> String:
	var parts := PackedStringArray()
	for kind: String in r.experiences:
		parts.append("%s %d" % [{"conversation": "talks", "gift": "gifts", "walk": "walks", "meal": "meals", "visit": "visits", "place": "outings"}.get(kind, kind), int(r.experiences[kind])])
	var counts := {}
	for promise: Variant in r.promises:
		if promise is Dictionary: counts[str(promise.get("status", ""))] = int(counts.get(str(promise.get("status", "")), 0)) + 1
	var said := ", ".join(parts)
	if not counts.is_empty():
		var kept := PackedStringArray()
		for status: String in counts: kept.append("%s %d" % [status, int(counts[status])])
		said += ("; " if not said.is_empty() else "") + "promises " + ", ".join(kept)
	return said

func prompt_for(id: String) -> String:
	if BOND.DYNAMIC: return _dynamic_prompt(id)
	var r := record_for(id)
	var known := knowledge(id)
	var stage := str(r.stage)
	if not bool(known.get("met", false)) and not bool(known.get("unknown", false)): stage = "none yet (you have not met)"
	var result := "Your actual relationship with Anon: %s. Trust %.0f/100, familiarity %.0f/100. Completed dates: %d. Shared home: %s." % [stage,r.trust,r.familiarity,r.dates,r.shared_home_id if not r.shared_home_id.is_empty() else "separate homes"]
	# The fixed rules (romance is separate from friendship, declining is allowed, no blanket permission,
	# no scores aloud, no unconfirmed milestones) ride once in the dialogue prompt's fixed head
	# (director_prompts.gd RELATIONSHIP_RULES); this block is only her live record.
	result += "\nYour friendship temperament: " + PERSONALITY.prompt(id)
	if not r.experiences.is_empty() or not r.promises.is_empty():
		# Counts, not the raw JSON (up to 16 promise records), 2026-11-19.
		result += "\nShared so far: " + _shared_words(r) if RULES.FACTS else "\nMeaningful shared experiences: " + JSON.stringify(r.experiences) + ". Promises: " + JSON.stringify(r.promises)
	result += "\nEligible relationship offers: " + JSON.stringify(available(id)) + "."
	var p := pending(id)
	if not p.is_empty():
		if RULES.FACTS:
			result += "\nPending offer %s from %s: %s%s. Only the other participant may answer it." % [str(p.id), "Anon" if p.by == "player" else "you", str(p.kind).replace("_", " "), " (" + str(p.activity) + ")" if p.kind in ["date", "outing"] else ""]
		else: result += "\nPending explicit offer: " + JSON.stringify(p) + ". Only the other participant may answer it."
	if not r.plan.is_empty():
		if RULES.FACTS:
			result += "\nYour planned %s with Anon, still to do: %s%s, about %d minutes left." % ["date" if bool(r.plan.get("date", false)) else "outing", str(r.plan.activity), (" at " + str(r.plan.get("place", ""))) if not str(r.plan.get("place", "")).is_empty() else "", maxi(1, roundi((float(r.plan.deadline) - now()) / 60.0))]
		else: result += "\nYour agreed plan, not yet completed: " + JSON.stringify(r.plan)
	if RULES.FACTS:
		if STAGES.find(str(r.stage)) < 3 and int(r.get("casual", 0)) > 0:
			result += "\nYou aren't a couple. What the two of you have shared so far is casual%s." % (", and some of it came before you had real feelings for him" if int(r.get("rushed", 0)) > 0 else "")
		var betrayed: Variant = r.get("betrayed")
		if betrayed is Dictionary and day() >= float((betrayed as Dictionary).get("day", 0.0)) and day() < float((betrayed as Dictionary).get("day", 0.0)) + 3.0:
			result += "\nYou've heard that Anon was intimate with %s while with you." % str((betrayed as Dictionary).get("with", "another mare"))
		var just := moments_line(id)
		if not just.is_empty(): result += "\n" + just
	if ready_to_ask(id):
		var w := _player_words()
		result += "\nOver your time together you've fallen for Anon, and you want to ask %s to be your %s. Wait for a quiet, happy moment, then ask %s in your own words as a relationship_offer of kind dating. It will hurt if %s says no, though that's %s choice to make." % [w.object, w.partner, w.object, str(w.subject).capitalize(), w.possessive]
	elif r.stage in ["friend", "close_friend"] and int(r.get("asks_left", ASKS)) <= 0:
		result += "\nAnon has turned you down twice, so don't ask him again. If he asks you instead, the choice is yours, and you both have to clearly agree."
	return result

## True while the player is a young AnonPony. Outside the tree (tests) the player is human Anon.
func _young_player() -> bool:
	return is_inside_tree() and PLAYER_FORM.is_young(PLAYER_FORM.active(get_tree()))

## {"subject", "object", "possessive", "noun", "partner"} for the player: he/him/his and
## "coltfriend" for human Anon (world/life/player_form.gd pronouns).
func _player_words() -> Dictionary:
	return PLAYER_FORM.pronouns(PLAYER_FORM.active(get_tree()) if is_inside_tree() else PLAYER_FORM.human())

# --- Relationship overhaul 2026-11-21 (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md, contract -------
# docs/RELATIONSHIP_BUILD_2026_11_21.md section 3.1). With BOND.DYNAMIC on, her tags say what she
# feels and what the two of them are; this node remembers the facts and her words and tells them.
# Nothing below compares a count, a time or a score to allow, refuse, end or move anything she
# feels or decides. Ages ("day", "t") are kept only so her prompt and the page can say how long ago.

const BOND := preload("res://world/relationships/bond_rules.gd")
const BOND_PROMPT := preload("res://world/relationships/bond_prompt.gd")
const MEMORY := preload("res://world/relationships/bond_memory.gd")
const PLACE_DIRECTORY := preload("res://world/navigation/place_directory.gd")

## A step between them was recorded. changed(id) is emitted as well.
signal stepped(id: String, kind: String, answer: String)
## She named a new closeness or heart step.
signal stood(id: String, ladder: String, step: String)

## Old step kinds (KINDS above) and the new ones (BOND.KINDS).
const NEW_KIND := {"dating": "couple", "engagement": "engaged", "marriage": "married"}
const OLD_STEP := {"couple": "dating", "engaged": "engagement", "married": "marriage"}
## Page wording (shown to the player only, never sent to a model). Listed in the report for review.
const PAGE_CLOSE := {"stranger": "You have not met yet.", "acquaintance": "Acquaintances.", "friend": "Friends.", "good_friend": "Good friends.",
	"best_friend": "Best friends.", "blood_brothers": "Blood brothers.", "kindred_soul": "Kindred souls."}
const PAGE_HEART := {"noticing": "She has begun to notice you.", "crush": "She has a crush on you.", "in_love": "She is in love with you.", "devoted": "She is devoted to you."}
const PAGE_STEP := {"acquaintance": "An acquaintance", "friend": "A friend", "good_friend": "A good friend", "best_friend": "A best friend",
	"blood_brothers": "Blood brothers", "kindred_soul": "A kindred soul", "noticing": "Noticing you", "crush": "A crush", "in_love": "In love", "devoted": "Devoted"}
const PAGE_HEART_STEPS := ["Noticing you", "A crush", "In love", "Devoted"]
const LOG_STOOD := {"acquaintance": "she says you are an acquaintance now", "friend": "she says you are a friend now", "good_friend": "she says you are a good friend now",
	"best_friend": "she says you are a best friend now", "blood_brothers": "she says you two are blood brothers now", "kindred_soul": "she says you are a kindred soul now",
	"none": "she says she has no feelings for you", "noticing": "she says she has begun to notice you", "crush": "she says she has a crush on you",
	"in_love": "she says she is in love with you", "devoted": "she says she is devoted to you"}
const LOG_TITLE := {"couple": "you became a couple", "engaged": "you got engaged", "married": "you got married", "move_in": "you agreed to share a home",
	"break_up": "you broke up", "ended": "you ended it from the page"}
const PAGE_KIND := {"kiss": "a kiss", "hug": "a hug", "outing": "an outing", "date": "a date", "couple": "being a couple", "move_in": "sharing a home",
	"engaged": "getting engaged", "married": "getting married", "break_up": "breaking up"}
const PAGE_SORE_NOTE := "Only she can forgive these. Saying sorry seldom does it. Showing her does."
const PAGE_UNDO := "Not what you meant? Tell her."
const PAGE_CLOSED := {"no": "She said no to a kiss.", "cold": "She is cross with you and does not want to be touched.", "space": "She asked for space.",
	"turned": "She turned away from your kiss and has not said anything about it since."}
const NUMBER_WORDS := ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]

# --- the record ---

## The day as the player reads it (TimeOfDay.day_number), for dating facts. Never compared to allow anything.
func _today() -> int:
	var clock := get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	if clock == null: return 0
	if clock.has_method("day_number"): return int(clock.call("day_number"))
	return int(clock.get("day"))

## Played seconds, for the wording of ages only.
func played() -> float:
	var clock := get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null
	var active: Variant = clock.get("active_seconds") if clock != null else null
	if active is float or active is int: return float(active)
	return Time.get_ticks_msec() * 0.001

func _age(day: int, t: float) -> String:
	if day < 0: return ""
	return BOND.age(maxf(0.0, played() - t), maxi(0, _today() - day))

## Her record for `r` (record_for() already added it).
static func _b(r: Dictionary) -> Dictionary:
	return r[BOND.SAVE_KEY]

func _status(r: Dictionary) -> String:
	return str(BOND.STATUS_FOR_STAGE.get(str(r.get("stage", "")), "none"))

static func _plain_stage(closeness: String) -> String:
	match closeness:
		"stranger", "acquaintance": return "acquaintance"
		"friend": return "friend"
	return "close_friend"

func _new_bond(id: String) -> Dictionary:
	var met: bool = bool(knowledge(id).get("met", false)) if context != null else false
	return MEMORY.fresh("acquaintance" if met else "stranger", _today(), played())

## A 0.3.1 record's bond (design 10.1), from what the old fields and the impression store held.
func _convert(id: String, r: Dictionary) -> Dictionary:
	var imp: Node = context.impressions if context != null and is_instance_valid(context.impressions) else null
	var xp: Dictionary = imp.call("old_xp", id) if imp != null and imp.has_method("old_xp") else {"friendship": 0, "romance": 0}
	var note: Dictionary = (imp.get("notes") as Dictionary).get(id, {}) if imp != null and imp.get("notes") is Dictionary else {}
	var seen := {"met": bool(knowledge(id).get("met", false)) or bool(knowledge(id).get("unknown", false)) and str(r.get("stage", "")) != "acquaintance",
		"friend_xp": int(xp.get("friendship", 0)), "love_xp": int(xp.get("romance", 0)),
		"enemy": maxi(0, -int(imp.core.get_score(id, "friendship"))) if imp != null and imp.get("core") != null else 0,
		"grudge": float(imp.call("old_grudge", id)) if imp != null and imp.has_method("old_grudge") else 0.0,
		"thought": str(note.get("thought", "")), "today": _today(), "calendar": day(), "t": played()}
	return MEMORY.convert(r, seen)

## The old fields, written from her steps (design 10.2) so that the switch off, 0.3.1 and mods read
## the same level names: stage, familiarity, trust, the space state, and the impression store's XP.
func _echo(id: String, r: Dictionary) -> void:
	var b := _b(r)
	var closeness := str(b.closeness)
	if _status(r) == "none": r.stage = _plain_stage(closeness)
	var known: Array = BOND.FIXED_KNOWN.get(closeness, [0.0, 0.0])
	r.familiarity = float(known[0])
	r.trust = 0.0 if not (b.sore as Array).is_empty() else float(known[1])
	(r.cooldowns as Dictionary)["boundary"] = now() + 1.0e9 if str(b.kiss_word) == "closed" and str(b.kiss_closed_by) == "space" else 0.0
	if context != null and is_instance_valid(context.impressions) and context.impressions.has_method("echo"):
		context.impressions.echo(id, int(BOND.FIXED_FRIEND_XP.get(closeness, 0)), _love_xp_of(r), _enemy_of(b))

func _love_xp_of(r: Dictionary) -> int:
	var heart := str(_b(r).heart)
	if heart == "devoted" and _status(r) == "married": return BOND.FIXED_LOVE_XP_MARRIED_DEVOTED
	return int(BOND.FIXED_LOVE_XP.get(heart, 0))

static func _enemy_of(b: Dictionary) -> float:
	return float(BOND.FIXED_HOSTILITY.get(MEMORY.gravest(b), 0.0))

## Stores her record: the old fields echoed, the world told, changed(id) emitted.
func _put(id: String, r: Dictionary) -> void:
	if context == null or context._read_only or id.is_empty(): return
	_echo(id, r)
	data.records[id] = r.duplicate(true)
	context.state.player_bonds = data.duplicate(true)
	context._changed()
	changed.emit(id)

func _dynamic_bind() -> void:
	var converted := false
	for id: String in data.records.keys():
		var row: Variant = data.records[id]
		if not row is Dictionary: continue
		var r: Dictionary = row
		r.offer = {}; r.permissions = {}
		if not (r.plan as Dictionary).is_empty(): r.plan.deadline = now() + plan_seconds()
		if r.get(BOND.SAVE_KEY) is Dictionary:
			MEMORY.complete(r[BOND.SAVE_KEY])
			continue
		r[BOND.SAVE_KEY] = _convert(id, r)
		converted = true
	if not context._read_only:
		for id: String in data.records.keys():
			if data.records[id] is Dictionary: _echo(id, data.records[id])
		context.state.player_bonds = data.duplicate(true)
		if converted: context._changed()
	# The adult mod's acts arrive as world records of kind "intimacy" (November 20 section 8.2).
	if context.has_signal("event_recorded") and not context.event_recorded.is_connected(_on_event):
		context.event_recorded.connect(_on_event)

## A row written from outside (a mod's debug tool, the cloud home): taken as it is (November 20
## section 8.2). A title the stored record did not have lifts her heart once to what that title
## meant on the old Love bar, a cleared space state ends her request for space, and a cleared plan
## is a plan called off.
func _dynamic_save(id: String, row: Dictionary) -> void:
	var r := row.duplicate(true)
	var stored: Dictionary = data.records.get(id, {}) if data.records.get(id) is Dictionary else {}
	if not r.get(BOND.SAVE_KEY) is Dictionary:
		r[BOND.SAVE_KEY] = (stored.get(BOND.SAVE_KEY) as Dictionary).duplicate(true) if stored.get(BOND.SAVE_KEY) is Dictionary else (_convert(id, r) if not stored.is_empty() else _new_bond(id))
	var b := _b(r)
	MEMORY.complete(b)
	for key: String in ["cooldowns", "plan", "promises", "experiences", "permissions", "offer"]:
		if not r.has(key): r[key] = record_for(id).get(key)
	var old_stage := str(stored.get("stage", ""))
	var stage := str(r.get("stage", ""))
	if BOND.CONVERT_TITLE_HEART.has(stage) and stage != old_stage:
		var meant := str(BOND.CONVERT_TITLE_HEART[stage])
		if BOND.heart_rank(str(b.heart)) < BOND.heart_rank(meant): b.heart = meant
		b.status_day = _today()
	var stored_bond: Dictionary = stored.get(BOND.SAVE_KEY, {}) if stored.get(BOND.SAVE_KEY) is Dictionary else {}
	if str(b.kiss_closed_by) == "space" and str(stored_bond.get("kiss_closed_by", "")) == "space" \
			and float((r.cooldowns as Dictionary).get("boundary", 0.0)) <= 0.0 and float((stored.get("cooldowns", {}) as Dictionary).get("boundary", 0.0)) > 0.0:
		b.kiss_word = "unsaid"; b.kiss_closed_by = ""
	if (r.plan as Dictionary).is_empty() and stored.get("plan") is Dictionary and not (stored.plan as Dictionary).is_empty():
		for promise: Dictionary in r.promises:
			if str(promise.get("id", "")) == str(stored.plan.get("id", "")) and str(promise.get("status", "")) == "pending": promise.status = "cancelled"
	_put(id, r)

# --- what happened: "Lately", the weighing line, the page's log ---

func _happened(b: Dictionary, kind: String, detail: Dictionary, weigh: bool) -> void:
	var text := BOND_PROMPT.event_text(kind, detail)
	if text.is_empty(): text = kind.replace("_", " ")
	var lately: Array = b.lately
	lately.push_front({"text": text, "kind": kind, "day": _today(), "t": played()})
	while lately.size() > BOND.LATELY: lately.pop_back()
	if not kind.begins_with("intimacy"): b.act_from = ""
	if weigh:
		var items: Array = b.weigh
		if not items.any(func(w: Variant) -> bool: return w is Dictionary and str((w as Dictionary).get("text", "")) == text and not bool((w as Dictionary).get("shown", false))):
			items.append({"text": text, "shown": false})

func _log(b: Dictionary, what: String, quote := "") -> void:
	var rows: Array = b.log
	rows.push_front({"day": _today(), "what": what, "quote": quote.left(BOND.WHY_MAX)})
	while rows.size() > BOND.LOG_KEPT: rows.pop_back()

func _meet(b: Dictionary) -> void:
	if str(b.closeness) != "stranger": return
	b.closeness = "acquaintance"
	b.closeness_day = _today()
	b.met_day = _today()
	b.met_t = played()
	_log(b, "you met")

# --- sore points (design section 6): opened by her word or by a fact, closed only by her forgiving ---

## True when it opened. One of a kind is open at a time: a second of the same kind re-words it
## (a rushed act again says so). `tell`: put it in "Lately" and the weighing line.
func _open_sore(id: String, r: Dictionary, kind: String, text: String, who := "", fact := true, tell := true, plan := "") -> bool:
	var b := _b(r)
	var open := MEMORY.sore_of(b, kind)
	if not open.is_empty():
		if kind == "rushed": open.again = true
		elif not text.is_empty(): open.text = text.left(BOND.WHY_MAX)
		if not who.is_empty(): open.who = who
		return false
	var row := MEMORY.sore_row(kind, text, who, _today(), played(), fact)
	row.plan = plan
	# A rushed act after an earlier one she forgave: "again".
	if kind == "rushed" and kind in (b.get("forgiven", []) as Array): row.again = true
	(b.sore as Array).push_front(row)
	# A fact means what she said before no longer speaks for her.
	if fact and str(b.kiss_word) == "open": b.kiss_word = "unsaid"
	if tell: _happened(b, "sore_opened", {"kind": kind, "who": who}, true)
	_log(b, "sore point: " + str((BOND.SORE.get(kind, {}) as Dictionary).get("label", kind)).to_lower(), text)
	if kind in BOND.TOWN_HEARS and context != null and is_instance_valid(context.impressions) and context.impressions.has_method("note_deed"):
		context.impressions.note_deed(id, "cheat" if kind == "betrayed" else "cruel", 1.0)
	return true

## Her forgiving: closes the sore point at `index` (1 the first listed, newest first; 0 or a number
## past the list, the first). False when none is open.
func _forgive(r: Dictionary, index: int, why: String) -> bool:
	var b := _b(r)
	var sores: Array = b.sore
	if sores.is_empty(): return false
	var at := index - 1 if index >= 1 and index <= sores.size() else 0
	var row: Dictionary = sores[at]
	sores.remove_at(at)
	var forgiven: Array = b.get("forgiven", [])
	if not str(row.kind) in forgiven: forgiven.append(str(row.kind))
	b.forgiven = forgiven
	_happened(b, "forgave", {"kind": str(row.kind), "who": str(row.get("who", ""))}, true)
	_log(b, "she forgave you: " + str((BOND.SORE.get(str(row.kind), {}) as Dictionary).get("label", row.kind)).to_lower(), why)
	return true

## Her word for the moment, from pony_impressions.commit (contract 3.1). `word` is a listed word
## (BOND.WORDS), "" for a commit with only a thought. Returns the word as it counted.
func felt_word(id: String, word: String, why: String, forgive: int, thought := "") -> String:
	if not BOND.DYNAMIC or context == null or context._read_only or id.is_empty(): return word
	var r := record_for(id)
	var b := _b(r)
	why = why.strip_edges().left(BOND.WHY_MAX)
	var judging: Dictionary = b.judging
	b.judging = {}
	if word in BOND.ROMANTIC_WORDS and (not eligible_for_romance(id) or _spa(id)): word = "pleased"
	var row: Dictionary = BOND.FELT.get(word, {})
	var sore := str(row.get("sore", ""))
	if bool(row.get("reason", false)) and why.is_empty():
		# A strong word without its reason counts as its mild neighbour; a cold one leaves nothing lasting.
		b.repair = "why"; b.repair_kind = ""; b.repair_shown = false
		word = str(row.get("mild", word))
		sore = ""
	if word == "forgiving" and not _forgive(r, forgive, why): word = "pleased"
	if word in BOND.COLD:
		if not (str(b.kiss_word) == "closed" and str(b.kiss_closed_by) in ["no", "space"]):
			b.kiss_word = "closed"; b.kiss_closed_by = "cold"
		if not sore.is_empty():
			# After he kissed, hugged or smacked her against her no or her request for space.
			_open_sore(id, r, "ignored_no" if str(judging.get("why", "")) in ["no", "space"] else sore, why, "", false)
	elif not word.is_empty() and word in BOND.WORDS:
		if str(b.kiss_word) == "closed" and str(b.kiss_closed_by) in ["cold", "turned"]: b.kiss_word = "unsaid"; b.kiss_closed_by = ""
		if word in BOND.WARM and str(b.kiss_word) == "closed" and str(b.kiss_closed_by) == "space": b.kiss_word = "unsaid"; b.kiss_closed_by = ""
		if (word == "smitten" or word == "flattered" and BOND.heart_rank(str(b.heart)) >= BOND.heart_rank("noticing")) and not (str(b.kiss_word) == "closed" and str(b.kiss_closed_by) == "no"):
			b.kiss_word = "open"; b.kiss_closed_by = ""
	var last := why if not why.is_empty() else thought.strip_edges()
	if not last.is_empty(): b.thought = {"text": last.left(240), "day": _today(), "t": played()}
	_put(id, r)
	return word

## A favour he did for her (asks.gd "askdone:ROW" / "ask:ROW"): once per row.
func favour(id: String, row: String) -> bool:
	if not BOND.DYNAMIC or context == null or context._read_only or row.is_empty(): return false
	var key := id + ":favour:" + row
	if data.seen.has(key): return false
	data.seen[key] = true
	var r := record_for(id)
	var b := _b(r)
	MEMORY.add(b, "favour")
	_happened(b, "favour", {}, true)
	_put(id, r)
	return true

func _spa(id: String) -> bool:
	var runtime := _relationships()
	var actor: Variant = runtime.actors.get(id) if runtime != null else null
	return is_instance_valid(actor) and (actor as Node).has_meta("spa_client")

# --- her standing and the steps between them (contract 3.1) ---

func stand(id: String, ladder: String, step_name: String, why: String, _facts: Dictionary) -> Dictionary:
	if not BOND.DYNAMIC: return {"ok": false, "changed": false, "reason": "off"}
	if context == null or context._read_only or id.is_empty(): return {"ok": false, "changed": false, "reason": "read only"}
	var r := record_for(id)
	var b := _b(r)
	why = why.strip_edges().left(BOND.WHY_MAX)
	match ladder:
		"friend":
			if step_name not in BOND.CLOSENESS or step_name == "stranger": return {"ok": false, "changed": false, "reason": "unknown step"}
			if str(b.closeness) == step_name: return {"ok": true, "changed": false, "reason": "same"}
			_meet(b)
			b.closeness = step_name; b.closeness_day = _today(); b.closeness_why = why
		"heart":
			if step_name not in BOND.HEART: return {"ok": false, "changed": false, "reason": "unknown step"}
			if not eligible_for_romance(id): return {"ok": false, "changed": false, "reason": "age"}
			if str(b.heart) == step_name: return {"ok": true, "changed": false, "reason": "same"}
			b.heart = step_name; b.heart_day = _today(); b.heart_why = why
			# A new heart step changes what her old no to a kiss was about.
			if str(b.kiss_word) == "closed" and str(b.kiss_closed_by) == "no": b.kiss_word = "unsaid"; b.kiss_closed_by = ""
		_:
			return {"ok": false, "changed": false, "reason": "unknown ladder"}
	_log(b, str(LOG_STOOD.get(step_name, step_name)), why)
	if not why.is_empty(): b.thought = {"text": why, "day": _today(), "t": played()}
	_put(id, r)
	stood.emit(id, ladder, step_name)
	return {"ok": true, "changed": true, "reason": ""}

func step(id: String, kind: String, answer: String, facts: Dictionary) -> Dictionary:
	var out := {"ok": false, "held": false, "became": "", "reason": ""}
	if not BOND.DYNAMIC: out.reason = "off"; return out
	if context == null or context._read_only or id.is_empty(): out.reason = "read only"; return out
	if kind not in BOND.KINDS: out.reason = "unknown kind"; return out
	if answer != "" and answer not in BOND.ANSWER_WORDS: out.reason = "unknown answer"; return out
	if kind in BOND.ROMANTIC_KINDS and not eligible_for_romance(id): out.reason = "age"; return out
	var r := record_for(id)
	var b := _b(r)
	if answer.is_empty():
		b.repair = "us_answer"; b.repair_kind = kind; b.repair_shown = false
		_put(id, r)
		out.reason = "no answer"
		return out
	match answer:
		"yes":
			if str(facts.get("felt", "")) in ["pressured", "annoyed", "hurt", "angry"]:
				# Her own two tags disagree: held, and she is asked once.
				b.repair = "us_cold"; b.repair_kind = kind; b.repair_shown = false
				_put(id, r)
				out.held = true; out.reason = "cold"
				return out
			if not bool(facts.get("he_spoke", false)):
				# She cannot answer for him: her yes is her asking.
				if kind == "break_up": _over(r, facts)
				else: _ask(r, kind, facts)
				_put(id, r)
				stepped.emit(id, kind, "ask")
				out.ok = true; out.became = kind + ":ask"
				return out
			var refused := _yes(id, r, kind, facts)
			if not refused.is_empty():
				_put(id, r)
				out.reason = refused
				return out
		"no": _no(r, kind, facts)
		"ask":
			if kind == "break_up":
				if _status(r) == "none": out.reason = "not a couple"; return out
				_over(r, facts)
			else: _ask(r, kind, facts)
		"refused": _refused(r, kind)
	_put(id, r)
	stepped.emit(id, kind, answer)
	out.ok = true
	return out

## Her yes, which stands at any heart and in any order (design 5.1). "" or why nothing was made
## (structure: a home to share, a couple to break up).
func _yes(id: String, r: Dictionary, kind: String, facts: Dictionary) -> String:
	var b := _b(r)
	var status := _status(r)
	var before := _undo_snapshot(r, kind)
	var made := true
	match kind:
		"kiss", "hug":
			b.kiss_word = "open"; b.kiss_closed_by = ""
		"outing", "date":
			if bool(facts.get("meet", false)): b.meet_kind = kind
			else: _open_plan(r, kind, facts)
		"couple":
			b.over = {}
			if status == "none":
				r.stage = "dating"; r.dating_since = day(); b.status_day = _today()
				_became(id, r, "couple", true)
			else: made = false
		"engaged":
			if status in ["none", "couple"]:
				if status == "none": r.dating_since = day()
				r.stage = "engaged"; r.engaged_since = day(); b.status_day = _today(); b.over = {}
				_became(id, r, "engaged", status == "none")
			else: made = false
		"married":
			if status != "married":
				if status == "none": r.dating_since = day()
				if status != "engaged": r.engaged_since = day()
				r.stage = "married"; b.status_day = _today(); b.over = {}
				_became(id, r, "married", status == "none")
			else: made = false
		"move_in":
			var home := str(facts.get("home", ""))
			if home.is_empty(): return "no home"
			r.shared_home_id = home
			_happened(b, "move_in", {}, false)
			_log(b, str(LOG_TITLE.move_in))
		"break_up":
			if status == "none": return "not a couple"
			_over(r, facts)
			made = false
	(b.answers as Dictionary)[kind] = {"answer": "yes", "day": _today(), "t": played(), "count": 0}
	if not (b.open_ask as Dictionary).is_empty() and str(b.open_ask.kind) == kind: b.open_ask = {}
	if made and kind != "hug":
		b.undo = kind
		b.undo_prev = before
	return ""

func _undo_snapshot(r: Dictionary, kind: String) -> Dictionary:
	var b := _b(r)
	return {"stage": r.stage, "dating_since": r.dating_since, "engaged_since": r.engaged_since, "shared_home_id": r.shared_home_id,
		"plan": (r.plan as Dictionary).duplicate(true), "promises": (r.promises as Array).duplicate(true), "kiss_word": b.kiss_word,
		"kiss_closed_by": b.kiss_closed_by, "status_day": b.status_day, "meet_kind": b.meet_kind,
		"answer": ((b.answers as Dictionary).get(kind, {}) as Dictionary).duplicate()}

func _became(id: String, r: Dictionary, kind: String, new_couple: bool) -> void:
	var b := _b(r)
	_happened(b, kind, {}, false)
	_log(b, str(LOG_TITLE.get(kind, kind)))
	if not new_couple: return
	# A new couple with another mare while she is his partner.
	_betray_partners(id)

## Every partner of his but `id` learns he was with `id` (design section 6, "betrayed her").
func _betray_partners(id: String) -> void:
	var who := _name(id)
	for other: String in data.records.keys():
		if other == id or not data.records[other] is Dictionary: continue
		var row := record_for(other)
		if _status(row) == "none": continue
		if _open_sore(other, row, "betrayed", "", who, true): _put(other, row)
		elif str(MEMORY.sore_of(_b(row), "betrayed").get("who", "")) != who:
			MEMORY.sore_of(_b(row), "betrayed").who = who
			_put(other, row)

func _open_plan(r: Dictionary, kind: String, facts: Dictionary) -> void:
	var b := _b(r)
	var activity := str(facts.get("activity", ""))
	if activity not in ACTIVITIES: activity = "walk"
	var place := str(facts.get("place", ""))
	if activity == "place" and place.is_empty(): activity = "walk"
	# One open plan at a time: a new yes replaces the open one, at no cost.
	_call_off(r)
	data.serial = int(data.serial) + 1
	var key := "bond_%d" % int(data.serial)
	r.plan = {"id": key, "activity": activity, "place": place, "date": kind == "date", "accepted_at": now(), "deadline": now() + plan_seconds()}
	(r.promises as Array).append({"id": key, "activity": activity, "status": "pending"})
	while (r.promises as Array).size() > 16: (r.promises as Array).pop_front()
	b.plan_day = _today()
	b.plan_t = played()

func _call_off(r: Dictionary) -> void:
	if (r.plan as Dictionary).is_empty(): return
	for promise: Dictionary in r.promises:
		if str(promise.get("id", "")) == str(r.plan.get("id", "")) and str(promise.get("status", "")) == "pending": promise.status = "cancelled"
	r.plan = {}

## A break-up takes two beats: said once, then final on a later turn. It never lapses.
func _over(r: Dictionary, facts: Dictionary) -> void:
	var b := _b(r)
	if _status(r) == "none": return
	var turn := int(facts.get("turn", 0))
	var over: Dictionary = b.over
	if over.is_empty():
		b.over = {"by": "him" if bool(facts.get("he_spoke", false)) else "her", "day": _today(), "t": played(), "turn": turn}
	elif turn <= 0 or int(over.get("turn", -1)) != turn:
		_end(r)

func _end(r: Dictionary) -> void:
	var b := _b(r)
	r.stage = _plain_stage(str(b.closeness))
	r.shared_home_id = ""
	r.permissions = {}
	r.offer = {}
	_call_off(r)
	b.over = {}; b.undo = ""; b.undo_prev = {}; b.status_day = -1
	_happened(b, "break_up", {}, false)
	_log(b, str(LOG_TITLE.break_up))

func _no(r: Dictionary, kind: String, facts: Dictionary) -> void:
	var b := _b(r)
	if kind == "break_up":
		_over(r, facts)
		return
	var answers: Dictionary = b.answers
	var before: Dictionary = answers.get(kind, {})
	var count := int(before.get("count", 0)) + 1 if str(before.get("answer", "")) == "no" else 1
	answers[kind] = {"answer": "no", "day": _today(), "t": played(), "count": count}
	if kind == "kiss": b.kiss_word = "closed"; b.kiss_closed_by = "no"
	# Called off by her while that plan is open: no cost.
	if kind in ["outing", "date"] and not (r.plan as Dictionary).is_empty() and bool(r.plan.get("date", false)) == (kind == "date"): _call_off(r)
	if not (b.open_ask as Dictionary).is_empty() and str(b.open_ask.kind) == kind: b.open_ask = {}

func _ask(r: Dictionary, kind: String, facts: Dictionary) -> void:
	var b := _b(r)
	data.serial = int(data.serial) + 1
	b.open_ask = {"id": "bond_%d" % int(data.serial), "kind": kind, "by": "her", "day": _today(), "t": played(),
		"activity": str(facts.get("activity", "")), "place": str(facts.get("place", "")), "home": str(facts.get("home", ""))}
	b.last_ask = {"kind": kind, "refused": false}

func _refused(r: Dictionary, kind: String) -> void:
	var b := _b(r)
	var ask: Dictionary = b.open_ask
	if not ask.is_empty() and str(ask.kind) == kind and str(ask.by) == "her":
		# He turned her question down: a fact in her block. It takes nothing from anywhere.
		var before: Dictionary = b.his_no
		b.his_no = {"kind": kind, "day": _today(), "t": played(), "count": int(before.get("count", 0)) + 1 if str(before.get("kind", "")) == kind else 1}
		b.last_ask = {"kind": kind, "refused": true}
		b.open_ask = {}
		_happened(b, "his_no", {"kind": kind}, false)
		return
	if str(b.undo) == kind and not (b.undo_prev as Dictionary).is_empty():
		var prev: Dictionary = b.undo_prev
		for key: String in ["stage", "dating_since", "engaged_since", "shared_home_id", "plan", "promises"]: r[key] = prev[key]
		for key: String in ["kiss_word", "kiss_closed_by", "status_day", "meet_kind"]: b[key] = prev[key]
		if (prev.answer as Dictionary).is_empty(): (b.answers as Dictionary).erase(kind)
		else: (b.answers as Dictionary)[kind] = prev.answer
		b.undo = ""; b.undo_prev = {}
		_log(b, "she took back her yes to " + str(PAGE_KIND.get(kind, kind)))
		return
	if kind == "break_up" and not (b.over as Dictionary).is_empty():
		b.over = {}
		return
	if kind in ["outing", "date"]: _call_off(r)

## She finished a line to Anon that he heard (contract 3.1). Counts nothing toward anything.
func replied(id: String, facts: Dictionary) -> void:
	if not BOND.DYNAMIC or context == null or context._read_only or id.is_empty(): return
	var r := record_for(id)
	var b := _b(r)
	_meet(b)
	b.seen_day = _today()
	if not bool(b.meeting):
		b.meeting = true
		b.occasions = int(b.occasions) + 1
	b.presses = {}
	b.judging = (b.last_touch as Dictionary).duplicate()
	b.last_touch = {}
	if bool(b.repair_shown): b.repair = ""; b.repair_kind = ""; b.repair_shown = false
	if bool(b.ask_shown): b.ask_flag = false; b.ask_shown = false
	b.weigh = (b.weigh as Array).filter(func(w: Variant) -> bool: return w is Dictionary and not bool((w as Dictionary).get("shown", false)))
	if bool(facts.get("answers_him", false)) and not bool(facts.get("tagged", false)):
		# No feeling tag: the reply counts as fine, and she is reminded once.
		if str(b.kiss_word) == "closed" and str(b.kiss_closed_by) in ["cold", "turned"]: b.kiss_word = "unsaid"; b.kiss_closed_by = ""
		b.repair = "felt"; b.repair_kind = ""; b.repair_shown = false
	_put(id, r)

## Something happened that the existing doors do not see (contract 3.1, BOND.EVENTS).
func fact(id: String, kind: String, detail := "") -> bool:
	if not BOND.DYNAMIC or context == null or context._read_only or id.is_empty() or kind not in BOND.EVENTS: return false
	var r := record_for(id)
	var b := _b(r)
	match kind:
		"her_touch":
			# Her own touch comes first: it opens what an older no, anger or request for space had closed.
			b.kiss_word = "open"; b.kiss_closed_by = ""
		"face_warm":
			MEMORY.add(b, "face_warm")
		"bucked":
			MEMORY.add(b, "bucked")
			b.presses = {}
		"parted":
			b.meeting = false
			b.presses = {}; b.last_touch = {}; b.undo = ""; b.undo_prev = {}
			if str(b.kiss_word) == "closed" and str(b.kiss_closed_by) == "space": b.kiss_word = "unsaid"; b.kiss_closed_by = ""
			if detail == "he_slept" and not (r.plan as Dictionary).is_empty():
				# He went to sleep on a plan agreed for now and she was not beside him: he stood her up.
				var plan: Dictionary = r.plan
				for promise: Dictionary in r.promises:
					if str(promise.get("id", "")) == str(plan.get("id", "")): promise.status = "missed"
				r.plan = {}
				MEMORY.add(b, "missed")
				_happened(b, "stood_up", {"activity": str(plan.get("activity", "")), "date": bool(plan.get("date", false))}, true)
				_open_sore(id, r, "stood_up", "", "", true, false, _plan_words(plan))
		"hug":
			MEMORY.add(b, "hugs")
			_happened(b, "hug", {}, true)
	_put(id, r)
	return true

# --- her body (design section 8) ---

## Her body's ready answer for "kiss", "hug" or "flank_touch": "yes", "no" or "surprised". A pure
## read of her last word, her own stated steps, her open sore points and the town talk she heard.
func stance(id: String, kind: String) -> String:
	if not BOND.DYNAMIC: return "yes" if welcomes(id, kind) else "no"
	var romantic := kind in ["kiss", "flank_touch"]
	if romantic and not eligible_for_romance(id): return "no"
	var r := record_for(id)
	var b := _b(r)
	if str(b.kiss_word) == "closed": return "no"
	var sore := not (b.sore as Array).is_empty()
	if not romantic:
		if sore: return "no"
		if str(b.kiss_word) == "open" or BOND.closeness_rank(str(b.closeness)) >= BOND.closeness_rank("friend") or _committed(r): return "yes"
		return "no"
	if str(b.kiss_word) == "open": return "yes"
	if sore: return "no"
	if (_status(r) != "none" or BOND.heart_rank(str(b.heart)) >= BOND.heart_rank("crush")) and _heard(id).is_empty(): return "yes"
	return "surprised"

func _committed(r: Dictionary) -> bool:
	return _status(r) != "none" and BOND.heart_rank(str(_b(r).heart)) >= BOND.heart_rank("crush")

## Town talk she has heard about him that is still running, "" when none.
func _heard(id: String) -> String:
	if context == null or not is_instance_valid(context.impressions) or not context.impressions.has_method("heard_about"): return ""
	return str(context.impressions.heard_about(id))

func _dynamic_contact(id: String, kind: String) -> bool:
	var answer := stance(id, kind)
	if answer == "yes": return true
	if context == null or context._read_only: return false
	var r := record_for(id)
	var b := _b(r)
	var presses: Dictionary = b.presses
	presses[kind] = int(presses.get(kind, 0)) + 1
	var n := int(presses[kind])
	var why := "surprised"
	if str(b.kiss_word) == "closed":
		why = {"no": "no", "cold": "cold", "space": "space"}.get(str(b.kiss_closed_by), "surprised")
	elif not (b.sore as Array).is_empty(): why = "sore"
	if kind == "kiss":
		if str(b.kiss_word) == "unsaid": b.kiss_word = "closed"; b.kiss_closed_by = "turned"
		MEMORY.add(b, "kiss_turned")
		_happened(b, "kiss_turned", {}, false)
	if why == "space": _open_sore(id, r, "ignored_no", "", "", true)
	elif kind == "kiss" and n >= BOND.PRESS_BUCK: _open_sore(id, r, "ignored_no", "", "", true)
	elif kind == "kiss" and n == BOND.PRESS_HINT: _open_sore(id, r, "hint", "", "", true)
	var no: Dictionary = (b.answers as Dictionary).get("kiss", {})
	var said_no := str(no.get("answer", "")) == "no"
	b.last_touch = {"kind": kind, "why": why, "presses": n, "no_day": int(no.get("day", -1)) if said_no else -1, "no_t": float(no.get("t", 0.0)) if said_no else 0.0}
	r.last_contact = now()
	_put(id, r)
	boundary.emit(id, anger(id), "flank_smack" if kind == "flank_touch" else kind)
	return false

## His touch was dropped without a turn, or he stepped back out of reach: the press count ends.
func touch_dropped(id: String) -> void:
	if not BOND.DYNAMIC or context == null or context._read_only: return
	var seen: Variant = peek(id).get(BOND.SAVE_KEY)
	if not seen is Dictionary or ((seen as Dictionary).get("presses", {}) as Dictionary).is_empty(): return
	var r := record_for(id)
	_b(r).presses = {}
	_put(id, r)

# --- intimacy a mod reported, and kisses (design 7.1) ---

## Sorts an act by what she herself had said: committed, casual or rushed. A kiss is never rushed.
func _sort_act(id: String, r: Dictionary, kind: String) -> String:
	var b := _b(r)
	var crush := BOND.heart_rank(str(b.heart)) >= BOND.heart_rank("crush")
	var sort := "committed" if _status(r) != "none" and crush else ("casual" if crush else "rushed")
	if kind == "kiss" and sort == "rushed": sort = "casual"
	if sort == "committed": r["close"] = int(r.get("close", 0)) + 1
	else: r["casual"] = int(r.get("casual", 0)) + 1
	if sort == "rushed": r["rushed"] = int(r.get("rushed", 0)) + 1
	if kind != "kiss":
		_happened(b, "intimacy_" + sort, {}, true)
		if sort == "rushed": _open_sore(id, r, "rushed", "", "", true, false)
		if sort != "committed":
			data.serial = int(data.serial) + 1
			var flings: Array = b.flings
			flings.append(int(data.serial))
			while flings.size() > BOND.FLING_TALK: flings.pop_front()
	return sort

## "Anon goes from mare to mare": his last BOND.FLING_TALK flings were with as many different mares.
## A description of a fact, true or not at any moment.
func fling_talk() -> bool:
	var all: Array = []
	for other: String in data.records.keys():
		var row: Variant = data.records[other]
		if not row is Dictionary or not (row as Dictionary).get(BOND.SAVE_KEY) is Dictionary: continue
		for serial: Variant in ((row as Dictionary)[BOND.SAVE_KEY] as Dictionary).get("flings", []): all.append([int(serial), other])
	if all.size() < BOND.FLING_TALK: return false
	all.sort_custom(func(a: Array, c: Array) -> bool: return int(a[0]) > int(c[0]))
	var who := {}
	for row: Array in all.slice(0, BOND.FLING_TALK): who[str(row[1])] = true
	return who.size() == BOND.FLING_TALK

func _act(id: String, r: Dictionary, kind: String) -> void:
	var sort := _sort_act(id, r, kind)
	_put(id, r)
	if sort != "committed" and fling_talk() and context != null and is_instance_valid(context.impressions) and context.impressions.has_method("note_deed"):
		context.impressions.note_deed(id, "fling", 1.0)
	_betray_partners(id)

## The adult mod's record of an act (kind "intimacy", subjects one pony and "player"): one act per stem.
func _on_event(event: Dictionary) -> void:
	if not BOND.DYNAMIC or context == null or context._read_only or str(event.get("kind", "")) != "intimacy": return
	var subjects: Array = event.get("subjects", []) if event.get("subjects") is Array else []
	if subjects.size() != 2 or not "player" in subjects: return
	var id := str(subjects[0]) if str(subjects[1]) == "player" else str(subjects[1])
	if id == "player" or not bool(adults.get(id, false)) or not eligible_for_romance(id): return
	var stem := str(event.get("id", "")).get_slice(":", 0)
	var r := record_for(id)
	var b := _b(r)
	var acts: Array = b.acts
	if stem.is_empty() or stem in acts: return
	acts.append(stem)
	while acts.size() > BOND.ACT_STEMS: acts.pop_front()
	if str(b.act_from) == "call":
		b.act_from = ""
		_put(id, r)
		return
	b.act_from = "record"
	_act(id, r, "intimacy")

# --- what she is told, and the page ---

func standing(id: String) -> Dictionary:
	if not BOND.DYNAMIC: return {}
	var r := record_for(id)
	var b := _b(r)
	var known := knowledge(id) if context != null else {}
	var romance := eligible_for_romance(id)
	var status := _status(r)
	var closeness := str(b.closeness)
	var heart := str(b.heart)
	var sores := []
	for row: Dictionary in b.sore:
		sores.append({"kind": str(row.kind), "text": str(row.get("text", "")), "who": str(row.get("who", "")),
			"age": _age(int(row.get("day", -1)), float(row.get("t", 0.0))), "fact": bool(row.get("fact", false)), "again": bool(row.get("again", false)), "plan": str(row.get("plan", ""))})
	var said_no := []
	var answers: Dictionary = b.answers
	for kind: String in answers:
		var row: Dictionary = answers[kind]
		if str(row.get("answer", "")) == "no": said_no.append({"kind": kind, "age": _age(int(row.get("day", -1)), float(row.get("t", 0.0))), "count": int(row.get("count", 1))})
	var his_no := {}
	if not (b.his_no as Dictionary).is_empty():
		his_no = {"kind": str(b.his_no.kind), "age": _age(int(b.his_no.get("day", -1)), float(b.his_no.get("t", 0.0))), "count": int(b.his_no.get("count", 1))}
	var open_ask := {}
	if not (b.open_ask as Dictionary).is_empty():
		open_ask = {"kind": str(b.open_ask.kind), "by": str(b.open_ask.by), "age": _age(int(b.open_ask.get("day", -1)), float(b.open_ask.get("t", 0.0)))}
	var over := {}
	if not (b.over as Dictionary).is_empty():
		over = {"by": str(b.over.by), "age": _age(int(b.over.get("day", -1)), float(b.over.get("t", 0.0)))}
	var touch := {}
	if not (b.last_touch as Dictionary).is_empty():
		var lt: Dictionary = b.last_touch
		touch = {"kind": str(lt.kind), "why": str(lt.why), "presses": int(lt.presses), "no_age": _age(int(lt.get("no_day", -1)), float(lt.get("no_t", 0.0)))}
	var plan := {}
	if not (r.plan as Dictionary).is_empty():
		plan = {"date": bool(r.plan.get("date", false)), "activity": str(r.plan.get("activity", "")), "place": _place_label(str(r.plan.get("place", ""))),
			"age": _age(int(b.get("plan_day", -1)), float(b.get("plan_t", 0.0)))}
	var lately := []
	for row: Dictionary in b.lately: lately.append({"text": str(row.text), "age": _age(int(row.get("day", -1)), float(row.get("t", 0.0)))})
	var thought := {}
	if not (b.thought as Dictionary).is_empty(): thought = {"text": str(b.thought.text), "age": _age(int(b.thought.get("day", -1)), float(b.thought.get("t", 0.0)))}
	var weigh := []
	for row: Dictionary in b.weigh: weigh.append(str(row.text))
	var casual := 0
	if status == "none" and int(r.get("casual", 0)) > 0: casual = 2 if int(r.get("rushed", 0)) > 0 else 1
	var talk := _heard(id)
	var done: Dictionary = b.done
	var title_kind: String = {"couple": "couple", "engaged": "engaged", "married": "married"}.get(status, "")
	return {"id": id, "name": _name(id), "met": bool(known.get("met", false)) or closeness != "stranger",
		"adult": bool(adults.get(id, true)), "romance": romance, "words": _player_words(),
		"first_meeting": closeness == "stranger" or closeness == "acquaintance" and MEMORY.empty_diary(b),
		"new": closeness == "acquaintance", "known": _age(int(b.met_day), float(b.met_t)),
		"closeness": closeness, "closeness_since": {"day": int(b.closeness_day), "why": str(b.closeness_why)},
		"heart": heart, "heart_since": {"day": int(b.heart_day), "why": str(b.heart_why)},
		"so_far": {"occasions": int(b.occasions), "company_s": float(b.company_s), "meal": int(done.get("meal", 0)), "walk": int(done.get("walk", 0)),
			"fishing": int(done.get("fishing", 0)), "orchard": int(done.get("orchard", 0)), "visit": int(done.get("visit", 0)),
			"places": maxi((b.places as Array).size(), int(done.get("place", 0))), "favour": int(done.get("favour", 0)), "outing": int(done.get("outing", 0)),
			"date": int(done.get("date", 0)), "meeting": int(done.get("meeting", 0)), "missed": int(done.get("missed", 0)),
			"kisses": int(done.get("kisses", 0)), "hugs": int(done.get("hugs", 0)), "gifts": int(done.get("gift", 0))},
		"status": status, "since_day": int(b.status_day) if status != "none" else -1,
		"title_matches": BOND.title_matches(title_kind, heart), "committed": _committed(r), "home": not str(r.shared_home_id).is_empty(), "home_label": _place_label(str(r.shared_home_id)),
		"sore": sores, "holding_back": not MEMORY.sore_of(b, "rushed").is_empty(), "wary": not sores.is_empty() or not talk.is_empty(),
		"said_no": said_no, "his_no": his_no, "open_ask": open_ask, "over": over, "undo": str(b.undo),
		"kiss_word": str(b.kiss_word), "kiss_closed_by": str(b.kiss_closed_by), "last_touch": touch,
		"plan": plan, "lately": lately, "casual": casual, "thought": thought, "town_talk": talk, "apart_days": maxi(0, _today() - int(b.seen_day)) if int(b.seen_day) >= 0 else 0,
		"wants_to_ask": _wants_to_ask(r), "pace": _pace(), "weigh": weigh,
		"weigh_next": {"friend": BOND.next_closeness(closeness),
			"heart": BOND.next_heart(heart) if romance and BOND.closeness_rank(closeness) >= BOND.closeness_rank("friend") else ""},
		"repair": str(b.repair), "repair_kind": str(b.repair_kind), "ask_flag": bool(b.ask_flag)}

## "couple" when she has said she has a crush or more, they are not a couple, no sore point is open
## and her last question to him was not refused (design 5.3). No count.
func _wants_to_ask(r: Dictionary) -> String:
	var b := _b(r)
	if _status(r) != "none" or BOND.heart_rank(str(b.heart)) < BOND.heart_rank("crush") or not (b.sore as Array).is_empty(): return ""
	if bool((b.last_ask as Dictionary).get("refused", false)): return ""
	return "couple"

static func _pace() -> String:
	var tree := Engine.get_main_loop() as SceneTree
	var settings: Node = tree.root.get_node_or_null("Settings") if tree != null and tree.root != null else null
	var value: Variant = settings.call("get_value", BOND.PACE_KEY) if settings != null and settings.has_method("get_value") else null
	if not (value is float or value is int): return "normal"
	if float(value) < 0.99: return "slow"
	if float(value) > 1.01: return "fast"
	return "normal"

## A place's name from the place directory, "" when it has none (the id is never shown as a name).
func _place_label(place: String) -> String:
	if place.is_empty() or not is_inside_tree(): return ""
	var found: Dictionary = PLACE_DIRECTORY.find(get_tree(), place)
	return str(found.get("label", ""))

## "a meal date", "a walk": what an open plan was, for the stood_up sore point.
static func _plan_words(plan: Dictionary) -> String:
	var activity := str(plan.get("activity", "walk"))
	return "%s %s" % [activity if activity != "place" else "trip", "date" if bool(plan.get("date", false)) else "outing"]

## The block for her prompt, without marking anything as sent.
func _block(id: String) -> String:
	return BOND_PROMPT.live(standing(id))

func page(id: String) -> Dictionary:
	if not BOND.DYNAMIC: return {}
	var s := standing(id)
	var r := record_for(id)
	var b := _b(r)
	var romance := bool(s.romance)
	var closeness := str(s.closeness)
	var heart := str(s.heart)
	var status := str(s.status)
	var stallion := _stallion(id)
	var titles := {"couple": "Your coltfriend" if stallion else "Your marefriend", "engaged": "Your fiance" if stallion else "Your fiancee", "married": "Your husband" if stallion else "Your wife"}
	var headline := (str(titles[status]) + "." if status != "none" else str(PAGE_CLOSE.get(closeness, "")))
	if romance and PAGE_HEART.has(heart): headline += " " + str(PAGE_HEART[heart])
	var ladders := {"friend": {"steps": FRIEND_STEP_NAMES, "at": BOND.CLOSENESS.find(closeness) - 1,
		"since": _since_line(closeness, int(b.closeness_day), str(b.closeness_why))}, "heart": {}}
	if romance:
		ladders.heart = {"steps": PAGE_HEART_STEPS, "at": BOND.HEART.find(heart) - 1, "since": _since_line(heart, int(b.heart_day), str(b.heart_why)) if heart != "none" else ""}
	var title := ""
	if status != "none" and not bool(s.title_matches): title = str(titles[status]) + ". She has not said she has feelings for you."
	var block := BOND_PROMPT.live(s)
	var told: Array = []
	if not block.is_empty():
		var lines := block.split("\n")
		for i in range(1, lines.size()):
			if not lines[i].strip_edges().is_empty(): told.append(lines[i])
	var next: Array = []
	var weigh_next: Dictionary = s.weigh_next
	for ladder: String in ["friend", "heart"]:
		var step_name := str(weigh_next.get(ladder, ""))
		if step_name.is_empty(): continue
		var sentence := BOND_PROMPT.step_sentence(ladder, step_name, id)
		if not sentence.is_empty(): next.append(sentence)
	var sores: Array = []
	for row: Dictionary in s.sore:
		var label := str((BOND.SORE.get(str(row.kind), {}) as Dictionary).get("label", row.kind))
		if str(row.kind) == "betrayed" and not str(row.who).is_empty(): label += " (with %s)" % str(row.who)
		sores.append({"text": label + (": '%s'" % str(row.text) if not str(row.text).is_empty() else ""), "age": str(row.age)})
	var log: Array = []
	for row: Dictionary in b.log: log.append({"day": int(row.day), "what": str(row.what), "quote": str(row.get("quote", ""))})
	var thought: Dictionary = s.thought
	return {"romance": romance, "headline": headline, "ladders": ladders, "title": title, "so_far": _so_far_words(s.so_far),
		"told": told, "next": next, "now": _now_lines(s, b), "sore": sores, "sore_note": PAGE_SORE_NOTE if not sores.is_empty() else "",
		"mood": ("Her last thought about you: '%s'" % str(thought.text)) if not thought.is_empty() else "", "heard": str(s.town_talk),
		"log": log, "can_ask": bool(s.met) and not bool(s.ask_flag), "can_end": status != "none",
		"undo": PAGE_UNDO if not str(s.undo).is_empty() else ""}

const FRIEND_STEP_NAMES := ["Acquaintance", "Friend", "Good Friend", "Best Friend", "Blood Brothers", "Kindred Soul"]

func _stallion(id: String) -> bool:
	var runtime := _relationships()
	var actor: Variant = runtime.actors.get(id) if runtime != null else null
	var identity: Variant = (actor as Node).get("identity") if is_instance_valid(actor) else null
	return identity != null and bool(identity.get("stallion"))

static func _since_line(step_name: String, at_day: int, why: String) -> String:
	if at_day < 0: return ""
	return "%s since day %d%s" % [str(PAGE_STEP.get(step_name, step_name)), at_day, (": '%s'" % why) if not why.is_empty() else ""]

static func _number(n: int) -> String:
	return str(NUMBER_WORDS[n]) if n >= 0 and n < NUMBER_WORDS.size() else "many"

static func _plural(n: int, one: String, many: String) -> String:
	return "%s %s" % [_number(n), one if n == 1 else many]

static func _so_far_words(so_far: Dictionary) -> String:
	var parts := PackedStringArray()
	var n := int(so_far.get("occasions", 0))
	if n > 0: parts.append("talked on " + _plural(n, "occasion", "occasions"))
	if float(so_far.get("company_s", 0.0)) > 0.0: parts.append("spent " + BOND.company(float(so_far.company_s)) + " together")
	for row: Array in [["meal", "shared %s", "meal", "meals"], ["walk", "gone on %s", "walk", "walks"], ["places", "been to %s together", "place", "places"],
			["outing", "kept %s", "outing", "outings"], ["date", "kept %s", "date", "dates"], ["favour", "done her %s", "favour", "favours"],
			["gifts", "given her %s", "gift", "gifts"], ["missed", "missed %s", "promise", "promises"]]:
		var count := int(so_far.get(str(row[0]), 0))
		if count > 0: parts.append(str(row[1]) % _plural(count, str(row[2]), str(row[3])))
	for row: Array in [["fishing", "fished together"], ["orchard", "bucked apples together"], ["visit", "visited each other"],
			["meeting", "met where you agreed"], ["kisses", "kissed"], ["hugs", "hugged"]]:
		var count := int(so_far.get(str(row[0]), 0))
		if count > 0: parts.append("%s %s" % [str(row[1]), BOND.times(count)])
	if parts.is_empty(): return "You two have not done anything together yet."
	if parts.size() == 1: return "You two have %s." % parts[0]
	return "You two have %s and %s." % [", ".join(parts.slice(0, parts.size() - 1)), parts[parts.size() - 1]]

func _now_lines(s: Dictionary, b: Dictionary) -> Array:
	var lines: Array = []
	var plan: Dictionary = s.plan
	if not plan.is_empty():
		var what := "%s %s" % [str(plan.activity) if str(plan.activity) != "place" else "trip", "date" if bool(plan.date) else "outing"]
		if not str(plan.place).is_empty(): what += " to " + str(plan.place)
		lines.append("A %s, agreed %s, not yet kept." % [what, str(plan.age) if not str(plan.age).is_empty() else "earlier"])
	var ask: Dictionary = s.open_ask
	if not ask.is_empty():
		if str(ask.by) == "her": lines.append("She asked you about %s, %s. She is waiting for your answer." % [str(PAGE_KIND.get(str(ask.kind), ask.kind)), str(ask.age)])
		else: lines.append("You asked her about %s, %s." % [str(PAGE_KIND.get(str(ask.kind), ask.kind)), str(ask.age)])
	for row: Dictionary in s.said_no:
		var line := "She said not yet to %s, %s." % [str(PAGE_KIND.get(str(row.kind), row.kind)), str(row.age)]
		if int(row.count) > 1: line += " That is %s now." % BOND.times(int(row.count))
		lines.append(line)
	var his: Dictionary = s.his_no
	if not his.is_empty(): lines.append("You turned down her question about %s, %s." % [str(PAGE_KIND.get(str(his.kind), his.kind)), str(his.age)])
	var over: Dictionary = s.over
	if not over.is_empty():
		lines.append("%s said it is over between you, %s. It is not final until it is said again." % ["You" if str(over.by) == "him" else "She", str(over.age)])
	if str(s.kiss_word) == "closed" and PAGE_CLOSED.has(str(s.kiss_closed_by)): lines.append(str(PAGE_CLOSED[str(s.kiss_closed_by)]))
	if bool(s.home): lines.append("You share a home.")
	if bool(b.get("ask_flag", false)): lines.append("You asked her to say where you two stand. She will on her next turn.")
	return lines

## The page's "End it": ends things at once and opens "ended it coldly".
func end_it(id: String) -> bool:
	if not BOND.DYNAMIC or context == null or context._read_only: return false
	var r := record_for(id)
	if _status(r) == "none": return false
	var b := _b(r)
	_end(r)
	_log(b, str(LOG_TITLE.ended))
	_open_sore(id, r, "ended_coldly", "", "", true)
	_put(id, r)
	context.record("relationship", "Anon ended your romantic relationship coldly. Do not assume continued romantic permission.", [id, "player"], [id, "player"])
	return true

## The page's "Ask her": her next turn that answers him carries the one line.
func ask_flag(id: String) -> void:
	if not BOND.DYNAMIC or context == null or context._read_only: return
	var r := record_for(id)
	_b(r).ask_flag = true
	_b(r).ask_shown = false
	_put(id, r)

## The block for her prompt; this call is what sends it (contract 3.1).
func _dynamic_prompt(id: String) -> String:
	if context != null and not context._read_only:
		var r := record_for(id)
		var b := _b(r)
		var touched := false
		var items: Array = b.weigh
		if not bool(b.meeting) and int(b.occasions) > 0:
			var text := BOND_PROMPT.event_text("met_again", {})
			if text.is_empty(): text = "met again"
			if not items.any(func(w: Variant) -> bool: return w is Dictionary and str((w as Dictionary).get("text", "")) == text and not bool((w as Dictionary).get("shown", false))):
				items.push_front({"text": text, "shown": false})
				touched = true
		var s := standing_from(id, r)
		for row: Dictionary in items:
			if not bool(row.get("shown", false)): row.shown = true; touched = true
		if not str(b.repair).is_empty() and not bool(b.repair_shown): b.repair_shown = true; touched = true
		if bool(b.ask_flag) and not bool(b.ask_shown): b.ask_shown = true; touched = true
		if touched: _put(id, r)
		return BOND_PROMPT.live(s)
	return _block(id)

## standing(id) for a record in hand (the same as stored once _put).
func standing_from(id: String, r: Dictionary) -> Dictionary:
	var stored: Variant = data.records.get(id)
	data.records[id] = r
	var s := standing(id)
	if stored == null: data.records.erase(id)
	else: data.records[id] = stored
	return s

## Fixed values for old readers (design 10.2).
func _dynamic_devotion(id: String) -> float:
	var r := record_for(id)
	var b := _b(r)
	if not (b.sore as Array).is_empty(): return BOND.FIXED_DEVOTION_SORE
	var row: Array = BOND.FIXED_DEVOTION.get(str(b.heart), [0.0, 0.4])
	return float(row[1 if _committed(r) else 0])

func _dynamic_state(id: String) -> Dictionary:
	var r := record_for(id)
	var b := _b(r)
	var s := standing(id)
	var levels: Dictionary = LADDER.compute({"standing": s, "stallion": _stallion(id)})
	var love: Dictionary = levels.get("love", {})
	var friend: Dictionary = levels.get("friendship", {})
	var partner_elsewhere := false
	for other: String in data.records.keys():
		if other != id and data.records[other] is Dictionary and _status(data.records[other]) != "none": partner_elsewhere = true
	var sores: Array = []
	for row: Dictionary in b.sore: sores.append({"kind": str(row.kind), "text": str(row.get("text", "")), "day": int(row.get("day", -1))})
	var said_no: Array = []
	var answers: Dictionary = b.answers
	for kind: String in answers:
		if str((answers[kind] as Dictionary).get("answer", "")) == "no": said_no.append({"kind": kind, "day": int(answers[kind].get("day", -1)), "count": int(answers[kind].get("count", 1))})
	var flings := {}
	var all: Array = []
	for other: String in data.records.keys():
		var row: Variant = data.records[other]
		if row is Dictionary and (row as Dictionary).get(BOND.SAVE_KEY) is Dictionary:
			for serial: Variant in ((row as Dictionary)[BOND.SAVE_KEY] as Dictionary).get("flings", []): all.append([int(serial), other])
	all.sort_custom(func(a: Array, c: Array) -> bool: return int(a[0]) > int(c[0]))
	for row: Array in all.slice(0, BOND.FLING_TALK): flings[str(row[1])] = true
	return {"version": 3, "stage": str(r.stage), "committed": _committed(r), "couple": _status(r) != "none",
		"romance_allowed": bool(adults.get(id, false)) and eligible_for_romance(id),
		"love_level": int(love.get("level", -1)), "love_name": str(love.get("name", "")), "love_xp": _love_xp_of(r),
		"friend_level": int(friend.get("level", 0)), "friend_name": str(friend.get("name", "")),
		"trust": float(r.trust), "familiarity": float(r.familiarity), "devotion": _dynamic_devotion(id),
		"welcomes_kiss": stance(id, "kiss") == "yes", "wary": wary(id),
		"mood": str(context.impressions.profile(id).mood) if context != null and is_instance_valid(context.impressions) else "neutral",
		"kisses": int(r.get("kisses", 0)), "casual": int(r.get("casual", 0)), "committed_intimacy": int(r.get("close", 0)),
		"rushed": int(r.get("rushed", 0)), "partner_elsewhere": partner_elsewhere, "flings_this_week": flings.size(),
		"closeness": str(b.closeness), "heart": str(b.heart), "sore": sores, "holding_back": not MEMORY.sore_of(b, "rushed").is_empty(),
		"said_no": said_no, "kiss_word": str(b.kiss_word)}

## Old step calls from mods route to the same step function as her [us: ...] (design 10.2).
func _dynamic_offer(id: String, kind: String, by: String, activity: String, home: String, place: String) -> String:
	if context == null or context._read_only or by not in ["player", "pony"]: return ""
	var new_kind := str(NEW_KIND.get(kind, kind))
	if new_kind not in BOND.KINDS: return ""
	if activity not in ACTIVITIES or (activity == "place" and place.is_empty()): return ""
	if new_kind in BOND.ROMANTIC_KINDS and not eligible_for_romance(id): return ""
	if by == "pony":
		var made := step(id, new_kind, "ask", {"source": "api", "activity": activity, "home": home, "place": place})
		return str((_b(record_for(id)).open_ask as Dictionary).get("id", "")) if bool(made.ok) else ""
	var r := record_for(id)
	data.serial = int(data.serial) + 1
	_b(r).open_ask = {"id": "bond_%d" % int(data.serial), "kind": new_kind, "by": "him", "day": _today(), "t": played(), "activity": activity, "place": place, "home": home}
	_put(id, r)
	return str(_b(r).open_ask.id)

func _dynamic_answer(id: String, key: String, by: String, accept: bool) -> bool:
	if context == null or context._read_only or by not in ["player", "pony"]: return false
	var ask: Dictionary = _b(record_for(id)).open_ask
	if ask.is_empty() or str(ask.get("id", "")) != key or (str(ask.by) == "her") == (by == "pony"): return false
	var kind := str(ask.kind)
	var facts := {"source": "api", "he_spoke": true, "activity": str(ask.get("activity", "")), "place": str(ask.get("place", "")), "home": str(ask.get("home", ""))}
	var made: Dictionary
	if accept: made = step(id, kind, "yes", facts)
	elif by == "pony": made = step(id, kind, "no", facts)
	else: made = step(id, kind, "refused", facts)
	context.record("relationship", "You and Anon %s the %s invitation." % ["both accepted" if accept else "did not agree to", str(OLD_STEP.get(kind, kind)).replace("_", " ")], [id, "player"], [id, "player"])
	return bool(made.ok)

func _dynamic_pending(id: String) -> Dictionary:
	var ask: Dictionary = _b(record_for(id)).open_ask
	if ask.is_empty(): return {}
	var activity := str(ask.get("activity", ""))
	return {"id": str(ask.get("id", "")), "kind": str(OLD_STEP.get(str(ask.kind), ask.kind)), "by": "pony" if str(ask.by) == "her" else "player",
		"activity": activity if activity in ACTIVITIES else "walk", "home": str(ask.get("home", "")), "place": str(ask.get("place", "")), "expires": now() + 180.0}

## "Would the game give her a turn to bring this up now" (design 5.3, 10.2), plus structure.
func _dynamic_eligible(id: String, kind: String) -> bool:
	if not adults.has(id) or kind not in KINDS: return false
	if kind in ROMANTIC and (not adults[id] or _young_player()): return false
	var r := record_for(id)
	var b := _b(r)
	var status := _status(r)
	if kind == "break_up": return status != "none"
	if not (b.sore as Array).is_empty(): return false
	match kind:
		"outing": return (r.plan as Dictionary).is_empty()
		"hug": return true
		"date": return (r.plan as Dictionary).is_empty() and BOND.heart_rank(str(b.heart)) >= BOND.heart_rank("noticing") and _heard(id).is_empty()
		"dating": return _wants_to_ask(r) == "couple" and _heard(id).is_empty()
		"move_in": return status != "none"
		"engagement": return status == "couple" and BOND.title_matches("engaged", str(b.heart))
		"marriage": return status == "engaged" and BOND.title_matches("married", str(b.heart))
		"kiss", "flank_touch": return stance(id, "kiss") == "yes"
	return false

## Structure and age only (design 5.1): her yes stands at any heart and in any order.
func _dynamic_agreeable(id: String, kind: String) -> bool:
	if not adults.has(id) or kind not in KINDS: return false
	if kind in ROMANTIC and (not adults[id] or _young_player()): return false
	var status := _status(record_for(id))
	match kind:
		"dating": return status == "none"
		"engagement": return status in ["none", "couple"]
		"marriage": return status != "married"
		"break_up": return status != "none"
	return true

func _dynamic_experience(id: String, kind: String, event_id: String) -> bool:
	if context._read_only or not adults.has(id) or kind not in ACTIVITIES + ["conversation", "gift"]: return false
	if event_id.is_empty() or data.seen.has(id + ":" + event_id): return false
	# Talks are counted from her replies; a letter she liked is the one talk that comes this way.
	if kind == "conversation" and not event_id.begins_with("letter-"): return false
	data.seen[id + ":" + event_id] = true
	while data.seen.size() > 512: data.seen.erase(data.seen.keys()[0])
	var r := record_for(id)
	var b := _b(r)
	if kind == "conversation":
		MEMORY.add(b, "letters")
		_put(id, r)
		return true
	var plan: Dictionary = r.plan
	var completes: bool = not plan.is_empty() and (str(plan.activity) == kind or kind == "gift" and str(plan.activity) == "meal" and event_id.begins_with("fed_"))
	r.experiences[kind] = int(r.experiences.get(kind, 0)) + 1
	r.last_met = now()
	MEMORY.add(b, kind)
	var place := str(plan.get("place", "")) if completes else ""
	if kind == "place" and not place.is_empty() and not place in b.places: (b.places as Array).append(place)
	_happened(b, kind, {"activity": kind, "place": _place_label(place), "item": ""}, true)
	if completes:
		var date := bool(plan.get("date", false))
		if date: r.dates = int(r.dates) + 1
		MEMORY.add(b, "date" if date else "outing")
		_happened(b, "date_kept" if date else "outing_kept", {"activity": str(plan.activity), "place": _place_label(str(plan.get("place", "")))}, true)
		for promise: Dictionary in r.promises:
			if str(promise.get("id", "")) == str(plan.id): promise.status = "kept"
		r.plan = {}
	_put(id, r)
	context.record("shared_player_activity", "You and Anon completed %s together%s." % [kind, " on your agreed date" if completes and plan.get("date", false) else ""], [id, "player"], [id, "player"], "bond-" + event_id)
	return true

func _dynamic_appointment(id: String, appointment_id: String, kept: bool) -> void:
	if context == null or context._read_only or id.is_empty() or appointment_id.is_empty(): return
	var key := id + ":appt:" + appointment_id
	if data.seen.has(key): return
	data.seen[key] = true
	var r := record_for(id)
	var b := _b(r)
	(r.promises as Array).append({"id": appointment_id, "activity": "place", "status": "kept" if kept else "missed"})
	while (r.promises as Array).size() > 16: (r.promises as Array).pop_front()
	var as_kind := str(b.meet_kind)
	b.meet_kind = ""
	if kept:
		r.last_met = now()
		if as_kind == "date": r.dates = int(r.dates) + 1
		MEMORY.add(b, as_kind if as_kind in ["date", "outing"] else "meeting")
		_happened(b, {"date": "date_kept", "outing": "outing_kept"}.get(as_kind, "meeting_kept"), {}, true)
	else:
		MEMORY.add(b, "missed")
		_happened(b, "stood_up", {}, true)
		_open_sore(id, r, "stood_up", "", "", true, false, {"date": "date", "outing": "outing"}.get(as_kind, "meeting"))
	_put(id, r)

static func valid_save(value: Variant) -> bool:
	if not value is Dictionary or not value.get("records") is Dictionary or value.records.size()>256: return false
	if not value.get("serial") is int and not value.get("serial") is float: return false
	for id: Variant in value.records:
		var r: Variant = value.records[id]
		if not id is String or not r is Dictionary or r.get("stage") not in STAGES: return false
		for key: String in ["familiarity","trust","dates","dating_since","engaged_since","anger","anger_at","last_contact","last_buck","last_visit_day","last_met"]:
			if not r.get(key) is int and not r.get(key) is float: return false
			if not is_finite(float(r[key])): return false
		for key: String in ["experiences","offer","plan","permissions","cooldowns"]:
			if not r.get(key) is Dictionary: return false
		if not r.get("promises") is Array or r.promises.size()>16 or not r.get("shared_home_id") is String: return false
		if r.has("bond") and not preload("res://world/relationships/bond_memory.gd").valid(r.bond): return false
		if not r.offer.is_empty():
			if r.offer.get("kind") not in KINDS or r.offer.get("by") not in ["pony","player"]: return false
			if not r.offer.get("id") is String or not r.offer.get("activity") in ACTIVITIES or not r.offer.get("home") is String: return false
			if not r.offer.get("expires") is float and not r.offer.get("expires") is int: return false
		if not r.plan.is_empty():
			if r.plan.get("activity") not in ACTIVITIES or not r.plan.get("id") is String or not r.plan.get("date") is bool: return false
			for key: String in ["accepted_at","deadline"]:
				if not r.plan.get(key) is int and not r.plan.get(key) is float: return false
		for permission: Variant in r.permissions.values():
			if not permission is Dictionary or not (permission.get("until") is float or permission.get("until") is int) or not (permission.get("uses") is float or permission.get("uses") is int): return false
		for v: Variant in r.cooldowns.values():
			if not (v is float or v is int) or not is_finite(float(v)): return false
		for v: Variant in r.experiences.values():
			if not (v is float or v is int): return false
		for p: Variant in r.promises:
			if not p is Dictionary or not p.get("id") is String or p.get("activity") not in ACTIVITIES or p.get("status") not in ["pending","kept","missed","cancelled"]: return false
	return true
