extends Node
## Derpy's post office (Animal Crossing style letters, dev 2026-10-29): drafts and their
## recipients, sealing at the courier's grab (craft score), and what happens when a letter
## arrives. The recipient reads it with one AI call (letter_reader_prompt.gd): her heart score,
## her decisions ([meet], relationship answers) and her reply letter; without AI a rule-based
## reply (letter_fallback.gd). The score scales friendship, trust and an occasional gift. Her
## reply is due the next morning at 07:00 and the courier drops it in Anon's mailbox. While a
## letter is pinned (until what it asked is done, or two days) she has it in her prompt; then
## the world event remains. Created by relationship_runtime.gd setup; contract:
## docs/LETTERS_PLAN_2026_10_29.md.
const STORE := preload("res://world/letters/letter_store.gd")
const SCORING := preload("res://world/letters/letter_scoring.gd")
const READER := preload("res://world/letters/letter_reader_prompt.gd")
const FALLBACK := preload("res://world/letters/letter_fallback.gd")
const LETTER_TEXT := preload("res://world/letters/letter_text.gd")
const LLM := preload("res://world/ai/llm_client.gd")
const CONFIG := preload("res://world/ai/ai_config.gd")
const PROMPTS := preload("res://world/ai/director_prompts.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
const PROFILES := preload("res://world/ai/feedback_classifier.gd")
const ADDRESSEE := preload("res://world/ai/addressee.gd")
const CATALOG := preload("res://world/inventory/item_catalog.gd")
const MEET_TIME := preload("res://world/life/appointments/meet_time.gd")
const GROUP := "letter_post"
const NOTES_GROUP := "pony_prompt_notes"
const POLL := 1.5
const RETRY_SECONDS := 60.0
const TRIES := 3
const MORNING_HOUR := 7.0
## Delivered before this hour ("last night"): the reply comes that same morning.
const NIGHT_ENDS := 4.0
const PIN_DAYS := 2.0
## M-AI-16 (player board #49: Dash came to town hall "but said she never got the letter"): the
## meeting's "met" used to unpin the letter that very moment, so her greeting at the meeting had no
## letter in her prompt. It now stays pinned this long after they meet.
const MET_PIN_HOURS := 2.0
## M-AI-16: an offer her reply makes waits this long (game days, from when he opened it) for them to
## meet; she makes it in person when he is within OFFER_NEAR_M of her, so its 180 s starts then.
const OFFER_DAYS := 3.0
const OFFER_NEAR_M := 4.0
## A booked meeting he learns of from the reply: her wait opens this long before the hour
## (appointments.gd EARLY_HOURS), and the reply must reach him by then.
const MEET_LEAD_HOURS := 0.75
const NOTE_CHARS := 700
const STATIONERY := ["plain", "cream", "floral", "hearts"]
## Small things a pony might tuck into a reply; each is checked with item_catalog.gd has().
const GIFTS := ["food:cupcake", "food:apple-fritter", "food:blueberry-muffin", "food:chocolate-chip-cookie",
	"food:caramel-apple", "goods:paper-floral", "goods:paper-hearts", "goods:potted-plant"]
const ASK_AGAIN := "Which place and time did you mean? Write back and tell me, and I'll be there."
## Offers a letter may answer. A yes to an outing, date or touch starts a short real-time plan or
## permission (player_bonds.gd answer) that would lapse, as a missed plan, before he reads her reply.
const LETTER_ANSWERS := ["dating", "move_in", "engagement", "marriage", "break_up"]
## Main-cast profiles: a name part they share with a background pony is theirs.
const MAIN_CAST := "res://world/ai/characters/%s.json"
const HONORIFICS := ["princess", "miss", "mrs", "mr", "ms", "dr", "my", "dearest", "sweet", "lovely", "little"]
signal letter_read(id: String, pony: String, score: int)
var game: Node
var llm: Node
## Tests: a node with day/hours instead of /root/TimeOfDay; place rows ([{id, label, her_home,
## player_home}]) instead of place_directory.gd; 1/0 forces the AI or fallback path.
var clock: Node
var places_override: Variant = null
var ai_override := -1
var _poll := 0.0
var _reading := ""
var _generation := 0
var _retry_at: Dictionary = {}
var _names: Dictionary = {}

static func find(tree: SceneTree) -> Node:
	return tree.get_first_node_in_group(GROUP) if tree != null else null

func setup(host: Node) -> void:
	game = host
	add_to_group(GROUP); add_to_group(NOTES_GROUP)
	if llm == null:
		llm = LLM.new(); llm.name = "LetterLlm"; add_child(llm)
	var context := _context()
	if context != null and context.has_signal("reopened") and not context.reopened.is_connected(_reopened): context.reopened.connect(_reopened)

func _reopened(_world_id: String) -> void:
	_generation += 1; _reading = ""; _retry_at.clear()
	if is_instance_valid(llm) and llm.has_method("cancel"): llm.cancel()

func row(id: String) -> Dictionary:
	return STORE.row(_context(), id)

# --- Drafts and sending ------------------------------------------------------------------------

## A fresh sheet becomes a draft letter (PAPER, on first use of held paper).
func new_draft(stationery: String) -> String:
	var id := STORE.create(_context(), {"kind": "letter", "from": "player", "stationery": stationery if stationery in STATIONERY else "plain",
		"status": "draft", "written_at": _now()})
	_save_soon()
	return id

func set_text(id: String, text: String) -> bool:
	var r := row(id)
	if r.is_empty() or r.kind != "letter" or r.status != "draft": return false
	var clipped := text.left(LETTER_TEXT.MAX_CHARS)
	return STORE.update(_context(), id, {"text": clipped, "to": recipient_of(clipped)})

## Every name a letter may open with, lower case words -> pony id; "" marks a name two ponies share.
func recipient_names() -> Dictionary:
	if not _names.is_empty(): return _names
	var profiles: Dictionary = PROFILES.profiles()
	# A full name, alias or nickname outranks a bare name part another pony shares; a shared part
	# goes to the main cast ("Twilight" is Twilight Sparkle, not Twilight Velvet).
	var strong := {}
	var weak := {}
	for id: String in profiles:
		var profile: Dictionary = profiles[id]
		var own: Array = [str(profile.get("name", id)), id.replace("_", " ")] + Array(profile.get("aliases", [])) + Array(ADDRESSEE.NICKNAMES.get(id, []))
		var own_keys: Array = own.map(func(name: Variant) -> String: return _name_key(str(name)))
		var rank := 1 if FileAccess.file_exists(MAIN_CAST % id) else 0
		for name: String in ADDRESSEE.names_for(id, profile):
			var key := _name_key(name)
			if key.is_empty(): continue
			var into: Dictionary = strong if key in own_keys else weak
			var held: Array = into.get(key, [id, rank])
			if held[0] != id and int(held[1]) == rank: held = ["", rank]
			elif int(held[1]) < rank: held = [id, rank]
			into[key] = held
	for key: String in weak: _names[key] = weak[key][0]
	for key: String in strong: _names[key] = strong[key][0]
	return _names

func recipient_of(text: String) -> String:
	var key := _name_key(LETTER_TEXT.greeting_name(text))
	if key.is_empty(): return ""
	var names := recipient_names()
	if names.has(key): return str(names[key])
	# "Princess Twilight", "my dear Fluttershy": the name after a title or endearment.
	var words := key.split(" ", false)
	while words.size() > 1 and words[0] in HONORIFICS:
		words.remove_at(0)
		var shorter := " ".join(words)
		if names.has(shorter): return str(names[shorter])
	return ""

func can_send(id: String) -> Dictionary:
	var r := row(id)
	var result := {"ok": false, "to": "", "to_name": "", "reason": ""}
	if r.is_empty() or r.kind != "letter" or r.from != "player":
		result.reason = "This isn't a letter"; return result
	if r.status != "draft":
		result.reason = "This letter is already sent"; return result
	if LETTER_TEXT.clean(str(r.text)).strip_edges().is_empty():
		result.reason = "Write something first"; return result
	var greeting: String = LETTER_TEXT.greeting_name(str(r.text))
	if greeting.is_empty():
		result.reason = "Start with Dear and a name"; return result
	var to := recipient_of(str(r.text))
	if to.is_empty():
		result.reason = "Derpy won't know who %s is" % greeting; return result
	return {"ok": true, "to": to, "to_name": display_name(to), "reason": ""}

## COURIER at the grab: the letter is sealed and its craft scored.
func dispatched(id: String) -> void:
	var r := row(id)
	if r.is_empty() or r.kind != "letter" or r.status != "draft": return
	var to: String = str(r.to) if not str(r.to).is_empty() else recipient_of(str(r.text))
	var craft: Dictionary = SCORING.craft(str(r.text), display_name(to) if not to.is_empty() else "", str(r.stationery))
	STORE.update(_context(), id, {"status": "in_flight", "to": to, "sent_at": _now(), "craft": int(craft.score)})
	# The briefcase saved the letter's removal at once; the world (this row, the courier's flight)
	# follows within a second instead of up to ten (world_context.gd save_soon).
	_save_soon()

## COURIER on arrival: she has it now; remembered, pinned and queued for reading.
func delivered(id: String) -> void:
	var r := row(id)
	if r.is_empty() or r.kind != "letter" or r.status not in ["in_flight", "draft"] or str(r.to).is_empty(): return
	if r.status == "draft": dispatched(id)
	var now := _now()
	# On her doorstep until she is home (letter_props.gd), then she keeps it in her house.
	STORE.update(_context(), id, {"status": "delivered", "delivered_at": now, "pinned": true, "pin_until": now + PIN_DAYS, "ai": "pending", "doorstep": true})
	var context := _context()
	if context != null and context.has_method("record"):
		context.record("letter_from_anon", "Anon wrote you a letter on day %d and Derpy's post brought it to you." % int(floorf(now)),
			[str(r.to), "player"], [str(r.to), "player"], "letter:" + id)
	_poll = 0.0

## COURIER/PAPER: in_mailbox, taken and opened, for her replies and notes.
func set_status(id: String, status: String) -> bool:
	var r := row(id)
	if r.is_empty() or r.kind == "letter" or status not in ["scheduled", "in_mailbox", "taken", "opened"]: return false
	if r.status == status: return true
	if r.status == "opened" or (r.status == "taken" and status != "opened"): return false
	var fields := {"status": status}
	if status == "opened": fields.opened_at = _now()
	return STORE.update(_context(), id, fields)

## A note she writes on her own (APPOINTMENTS: stood up), due in Anon's mailbox next morning.
func pony_writes(pony: String, about: String, mood: String) -> String:
	var now := _now()
	var due := due_after(now)
	var id := STORE.create(_context(), {"kind": "note", "from": pony, "to": "player", "stationery": "plain", "status": "scheduled",
		"text": FALLBACK.note(display_name(pony), mood, pony + str(now)), "written_at": now, "due_at": due, "gist": about.left(160), "ai": "fallback"})
	if id.is_empty(): return ""
	var context := _context()
	if context != null and context.has_method("record"):
		context.record("letter_to_anon", "You wrote Anon a note about it (%s); Derpy will bring it to him in the morning." % mood, [pony], [pony, "player"], "note:" + id)
	var courier := _courier()
	if courier != null: courier.schedule_drop(id, due)
	return id

## The morning a reply to something that arrived at `at` is due: 07:00 next day, or that same
## morning when it arrived before 04:00.
static func due_after(at: float) -> float:
	var day := floorf(at)
	var hours := (at - day) * 24.0
	return day + (0.0 if hours < NIGHT_ENDS else 1.0) + MORNING_HOUR / 24.0

# --- Her prompt -------------------------------------------------------------------------------

## Pinned letters Anon sent her, newest two, at most NOTE_CHARS; "" when none.
func prompt_note(pony: String) -> String:
	var pinned: Array = []
	for r: Dictionary in STORE.rows(_context()).values():
		if r.kind == "letter" and r.from == "player" and r.to == pony and bool(r.pinned) and str(r.status) in ["delivered", "read"]:
			pinned.append(r)
	if pinned.is_empty(): return ""
	pinned.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.delivered_at) > float(b.delivered_at))
	pinned = pinned.slice(0, 2)
	var lines: PackedStringArray = []
	for r: Dictionary in pinned:
		var head := "- Anon's letter to you (day %d, by Derpy's post): \"" % int(floorf(float(r.delivered_at)))
		var reply := row(str(r.reply_id))
		var tail := "\"" + (" You wrote back: \"%s\"." % str(reply.get("gist", "")).left(140) if not reply.is_empty() else "")
		var room := NOTE_CHARS / pinned.size() - head.length() - tail.length() - 1
		var text := LETTER_TEXT.clean(str(r.text)).replace("\n", " ").strip_edges()
		if text.is_empty(): text = str(r.gist)
		if text.length() > room: text = text.left(maxi(0, room - 1)) + "…"
		lines.append(head + text + tail)
	return "\n".join(lines).left(NOTE_CHARS)

# --- Reading ----------------------------------------------------------------------------------

func _process(delta: float) -> void:
	_poll -= delta
	if _poll > 0.0: return
	_poll = POLL
	tick()

## Unpins what is done and starts the next waiting read (one request at a time).
func tick() -> void:
	var context := _context()
	if context == null or bool(context.get("_read_only")): return
	var appointments := _appointments()
	if appointments != null and appointments.has_signal("appointment_resolved") and not appointments.appointment_resolved.is_connected(_on_appointment_resolved):
		appointments.appointment_resolved.connect(_on_appointment_resolved)
	var now := _now()
	var rows := STORE.rows(context)
	var ids: Array = rows.keys()
	ids.sort_custom(func(a: String, b: String) -> bool: return STORE.serial_of(a) < STORE.serial_of(b))
	var next := ""
	for id: String in ids:
		var r: Dictionary = rows[id]
		if r.kind == "reply" and not str(r.get("offer", "")).is_empty() and str(r.get("offer_state", "")).is_empty() and str(r.status) == "opened": _offer_in_person(id, r, now)
		if r.kind != "letter": continue
		if bool(r.pinned) and _pin_done(r, now, appointments): STORE.update(context, id, {"pinned": false})
		if next.is_empty() and _reading.is_empty() and r.status == "delivered" and (r.ai == "pending" or str(r.ai).begins_with("retry:")) \
				and Time.get_ticks_msec() >= int(_retry_at.get(id, 0)):
			next = id
	if not next.is_empty(): _read(next)

## Pinned PIN_DAYS at most, so a meeting days ahead does not keep the letter in every prompt
## (her appointment note carries where and when); earlier when her meeting moved or resolved.
func _pin_done(r: Dictionary, now: float, appointments: Node) -> bool:
	var until := float(r.pin_until) if float(r.pin_until) >= 0.0 else float(r.delivered_at) + PIN_DAYS
	if now > until: return true
	if str(r.appointment).is_empty() or appointments == null: return false
	return str((appointments.call("open_for", str(r.to)) as Dictionary).get("id", "")) != str(r.appointment)

func _on_appointment_resolved(appointment: Dictionary) -> void:
	var context := _context()
	var source := str(appointment.get("source", ""))
	for id: String in STORE.rows(context):
		var r: Dictionary = STORE.rows(context)[id]
		if bool(r.pinned) and (str(r.appointment) == str(appointment.get("id", "")) or source == "letter:" + id):
			if str(appointment.get("status", "")) == "met":
				# They are meeting now: the letter stays in her prompt a while longer (#49).
				STORE.update(context, id, {"appointment": "", "pin_until": _now() + MET_PIN_HOURS / 24.0})
			else:
				STORE.update(context, id, {"pinned": false})

func _read(id: String) -> void:
	if not ai_available():
		_apply(id, {}, "fallback"); return
	var request := build_request(id)
	if request.is_empty():
		_apply(id, {}, "fallback"); return
	_reading = id
	_generation += 1
	var generation := _generation
	_configure_llm()
	var accepted: bool = llm.complete_limited(str(request.system), [{"role": "user", "content": str(request.user)}],
		func(reply: String, error: String) -> void:
			if generation != _generation: return
			_reading = ""
			if not error.is_empty() or reply.strip_edges().is_empty(): _failed(id)
			else: _apply(id, READER.parse(reply, request.context), "done"), READER.LIMITS)
	if not accepted:
		_reading = ""; _failed(id)

func ai_available() -> bool:
	if ai_override >= 0: return ai_override == 1
	var director := _director()
	return director != null and director.get("config") != null and CONFIG.ai_enabled(director.config)

func _configure_llm() -> void:
	var director := _director()
	if director == null or not director.has_method("_llm_section") or not llm.has_method("configure"): return
	llm.configure(director._llm_section())
	var main: Variant = director.get("llm")
	if main is Node: llm.set("status_path", (main as Node).get("status_path"))
	if llm.has_signal("usage_reported") and director.has_method("_on_llm_usage") and not llm.usage_reported.is_connected(director._on_llm_usage):
		llm.usage_reported.connect(director._on_llm_usage)

## Retried after RETRY_SECONDS with the same prompt (never toned down); the third failure
## falls back to the rule-based reply.
func _failed(id: String) -> void:
	var r := row(id)
	if r.is_empty(): return
	var tries := (str(r.ai).trim_prefix("retry:").to_int() if str(r.ai).begins_with("retry:") else 0) + 1
	if tries >= TRIES:
		_apply(id, {}, "fallback"); return
	STORE.update(_context(), id, {"ai": "retry:%d" % tries})
	_retry_at[id] = Time.get_ticks_msec() + int(RETRY_SECONDS * 1000.0)

## {"system", "user", "context"} for one letter, {} when it cannot be read.
func build_request(id: String) -> Dictionary:
	var r := row(id)
	if r.is_empty(): return {}
	var pony: String = r.to
	var context := _context()
	var clean := LETTER_TEXT.clean(str(r.text))
	var places := place_rows(pony)
	var pairs: Array = places.map(func(p: Dictionary) -> Array: return [str(p.id), str(p.label)])
	var bonds: Node = _bonds()
	var impressions: Node = context.get("impressions") if context != null else null
	var offer := ""
	if bonds != null and bonds.has_method("pending"):
		var pending: Dictionary = bonds.pending(pony)
		if not pending.is_empty() and str(pending.get("by", "")) == "player" and str(pending.get("kind", "")) in LETTER_ANSWERS:
			offer = "Anon's open offer to you: %s (%s), id %s; answer with [relationship_answer: %s, yes|no] only if the letter answers it." % [str(pending.kind), str(pending.get("activity", "")), str(pending.id), str(pending.id)]
	var appointments := _appointments()
	var at := float(r.sent_at) if float(r.sent_at) >= 0.0 else float(r.written_at)
	var now := _now()
	var parts := {"name": display_name(pony), "persona": persona(pony),
		"standing": impressions.standing_line(pony) if is_instance_valid(impressions) and impressions.has_method("standing_line") else "",
		"bonds": bonds.prompt_for(pony) if bonds != null and bonds.has_method("prompt_for") else "",
		"memory": _memory(pony, clean),
		"today": "Today: day %d, %s." % [int(floorf(now)), _clock_text(now)],
		"appointment": str(appointments.call("prompt_note", pony)) if appointments != null else "",
		"offer": offer, "places": pairs}
	var day := int(floorf(at))
	var decode: Dictionary = READER.decode_context(pairs, _relationship_context(pony), {"day": int(floorf(now)), "hours": (now - floorf(now)) * 24.0})
	# A favour by letter (world/mechanics/asks/asks.gd), only while she has room for one.
	var asks := _asks()
	var favour: Dictionary = asks.call("letter_context", pony) if asks != null else {}
	parts.letter_offer = READER.offer_line(letter_offer_kinds(pony))
	if not favour.is_empty():
		parts.favour = READER.FAVOUR
		(decode.capabilities as Array).append("ask")
		decode.merge(favour, true)
	return {"system": READER.system_prompt(parts), "user": READER.user_message(str(r.text), str(r.stationery), day, (at - day) * 24.0),
		"context": decode}

func _apply(id: String, parsed: Dictionary, mode: String) -> void:
	var r := row(id)
	var context := _context()
	if r.is_empty() or r.status != "delivered" or context == null: return
	_retry_at.erase(id)
	var pony: String = r.to
	var ai := mode == "done"
	var craft: int = int(r.craft) if int(r.craft) >= 0 else int(SCORING.craft(str(r.text), display_name(pony), str(r.stationery)).score)
	var heart: int = int(parsed.get("heart", 50)) if ai else SCORING.fallback_heart(craft)
	var score := SCORING.total(craft, heart)
	var her_name := display_name(pony)
	var signed: Dictionary = LETTER_TEXT.sign_off(str(r.text))
	var his_name := str(signed.get("name", "")) if bool(signed.get("found", false)) else ""
	var gist := str(parsed.get("gist", "")) if ai else ""
	if gist.is_empty(): gist = _gist(LETTER_TEXT.clean(str(r.text)))
	var appointment := ""
	var booked := {}
	var ask := false
	var confirm := ""
	var appointments := _appointments()
	var asked := _asked_meeting(r)
	if ai:
		for action: Dictionary in parsed.get("actions", []):
			var outcome := _dispatch(pony, id, action, gist)
			if bool(outcome.get("ask", false)): ask = true
			elif outcome.has("id"): appointment = str(outcome.id); booked = outcome.get("row", {})
		for dropped: Variant in parsed.get("dropped", []):
			if str(dropped).to_lower().begins_with("[meet"): ask = true
	elif appointments != null and not asked.is_empty():
		var result: Dictionary = appointments.call("propose", pony, str(asked.place), str(asked.day), str(asked.time), "letter:" + id, gist.left(120))
		if bool(result.get("ok", false)):
			appointment = str(result.get("id", ""))
			booked = result.get("row", {})
		else: ask = true
	# M-AI-18 (board #14): he asked her to come and she agreed ([come]; without AI a fair letter that
	# asks it). Her day plan walks her to where he is now (appointments.gd come); no telepathy.
	var coming := false
	if appointment.is_empty() and appointments != null and appointments.has_method("come") \
			and (bool(parsed.get("come", false)) if ai else (asked.is_empty() and FALLBACK.asks_to_come(str(r.text)) and score >= COME_SCORE)):
		var called: Dictionary = appointments.call("come", pony, "letter:" + id, ("he asked you to come: " + gist).left(120))
		if bool(called.get("ok", false)):
			appointment = str(called.get("id", "")); booked = called.get("row", {}); coming = true
	var due := due_after(float(r.delivered_at))
	# He learns of her meeting from this reply. One that starts before the reply would reach him
	# (she named an earlier time, or today) comes to him right away; and unless it is the very
	# meeting he asked for, missing it before reading her reply costs nothing (meeting_known).
	var known := true
	if not booked.is_empty():
		var meet_at := float(booked.get("day", 0)) + float(booked.get("hour", 12.0)) / 24.0
		known = _same_meeting(asked, booked, float(r.sent_at) if float(r.sent_at) >= 0.0 else float(r.delivered_at)) or meet_at - MEET_LEAD_HOURS / 24.0 >= due
		if not known: due = maxf(_now(), float(r.delivered_at))
		if not ai and coming: confirm = "I'm on my way to you now!"
		elif not ai:
			# Worded for when he reads it: "today" is the day the reply arrives.
			var read_day := int(floorf(due))
			confirm = "%s %s at %s, I'll be there!" % [str(booked.get("place_label", "There")), FALLBACK.spoken_day(int(booked.get("day", read_day)), read_day), FALLBACK.spoken_time(float(booked.get("hour", 12.0)))]
	var impression: Dictionary = parsed.get("impression", {}) if ai else {}
	_effects(pony, id, score, impression, ai)
	var gift := _gift(pony, id, score, ai and bool(parsed.get("gift", false)), ai)
	var reply_text := str(parsed.get("reply", "")) if ai else ""
	if reply_text.strip_edges().is_empty(): reply_text = FALLBACK.reply(her_name, his_name, score, id, confirm)
	if ask: reply_text = insert_before_sign_off(reply_text, ASK_AGAIN)
	if not reply_text.strip_edges().to_lower().begins_with("dear"): reply_text = "Dear Anon,\n" + reply_text.strip_edges()
	reply_text = reply_text.left(LETTER_TEXT.MAX_CHARS)
	var reply_id := STORE.create(context, {"kind": "reply", "from": pony, "to": "player", "stationery": "floral" if score >= 70 else "plain",
		"text": reply_text, "status": "scheduled", "written_at": _now(), "due_at": due, "reply_to": id,
		"gist": _gist(SCORING.body_text(reply_text, true, true)), "gift": gift, "appointment": appointment, "ai": mode,
		"offer": str(parsed.get("offer", "")) if ai and str(parsed.get("offer", "")) in letter_offer_kinds(pony) else ""})
	STORE.update(context, id, {"status": "read", "craft": craft, "heart": heart, "score": score, "gist": gist, "reply_id": reply_id,
		"appointment": appointment, "meet_known": known, "ai": mode})
	var courier := _courier()
	if courier != null and not reply_id.is_empty(): courier.schedule_drop(reply_id, due)
	if context.has_method("record"):
		context.record("letter_read", "Anon wrote you a letter on day %d: %s. You wrote back: %s" % [int(floorf(float(r.delivered_at))), gist, row(reply_id).get("gist", "")],
			[pony], [pony, "player"], "letter-read:" + id)
	_gossip(pony, id, score)
	letter_read.emit(id, pony, score)

## A fair letter is enough for her to come without AI (rule-based reply).
const COME_SCORE := 40

## M-AI-16: offer kinds her letter may make now (letter_reader_prompt.gd OFFER_KINDS she is eligible
## for, not on a refusal wait; dating only once she is ready to ask, as in person).
func letter_offer_kinds(pony: String) -> Array:
	var bonds := _bonds()
	if bonds == null or not bonds.has_method("eligible"): return []
	var kinds: Array = []
	for kind: String in READER.OFFER_KINDS:
		if not bool(bonds.eligible(pony, kind)) or bool(bonds.offer_on_cooldown(pony, kind)): continue
		if kind == "dating" and bonds.has_method("ready_to_ask") and not bool(bonds.ready_to_ask(pony)): continue
		kinds.append(kind)
	return kinds

## M-AI-16: the offer her opened reply carries is made in person when they next meet (the
## director's relationship intent: her own words and [relationship_offer] tag, as when she asks
## face to face), so player_bonds.gd's 180 s window starts then. Lapses after OFFER_DAYS.
func _offer_in_person(id: String, r: Dictionary, now: float) -> void:
	var context := _context()
	if float(r.get("opened_at", -1.0)) >= 0.0 and now - float(r.opened_at) > OFFER_DAYS:
		STORE.update(context, id, {"offer_state": "lapsed"}); return
	var pony := str(r.from)
	var kind := str(r.offer)
	if not _offer_ready(pony, kind): return
	var director := _director()
	if director == null or not director.has_method("request_relationship_intent"): return
	var asked: bool = director.call("request_relationship_intent", pony, {"kind": "relationship_offer", "offer_kind": kind, "activity": "walk"},
		_offer_ready.bind(pony, kind)) == true
	if asked:
		STORE.update(context, id, {"offer_state": "asked"})
		if context.has_method("record"):
			context.record("letter_offer", "You asked Anon in person what your letter said you would (%s)." % kind.replace("_", " "), [pony], [pony, "player"], "letter-offer:" + id)

## He is within OFFER_NEAR_M of her, she is free, and the offer is still hers to make.
func _offer_ready(pony: String, kind: String) -> bool:
	var bonds := _bonds()
	if bonds == null or not (kind in letter_offer_kinds(pony)) or not (bonds.pending(pony) as Dictionary).is_empty(): return false
	var population: Variant = game.get("population") if game != null else null
	var entry: Variant = (population.live as Dictionary).get(pony) if population is Node and "live" in population else null
	var actor: Variant = (entry as Dictionary).get("actor") if entry is Dictionary else null
	if not actor is Node3D or not is_instance_valid(actor) or not (actor as Node3D).is_inside_tree() or (actor as Node3D).get("sleeping") == true or (actor as Node3D).get("_held") == true: return false
	var player: Variant = game.get("player") if game != null else null
	var camera: Variant = game.call("_find_camera", player) if game != null and game.has_method("_find_camera") and is_instance_valid(player) else null
	return camera is Node3D and is_instance_valid(camera) and (actor as Node3D).global_position.distance_to((camera as Node3D).global_position) < OFFER_NEAR_M

## One of her tagged decisions: {"id", "row"} for a meeting made or moved ({"id"} for one called
## off), {"ask": true} when a meeting could not be booked, or {}.
func _dispatch(pony: String, id: String, action: Dictionary, gist: String) -> Dictionary:
	var appointments := _appointments()
	var bonds := _bonds()
	match str(action.get("type", "")):
		"meet":
			if appointments == null: return {"ask": true}
			var result: Dictionary = appointments.call("propose", pony, str(action.get("location_id", "")), str(action.get("day", "today")), str(action.get("time", "")), "letter:" + id, gist.left(120))
			return {"id": str(result.get("id", "")), "row": result.get("row", {})} if bool(result.get("ok", false)) else {"ask": true}
		"meet_cancel":
			if appointments == null: return {}
			var open: Dictionary = appointments.call("open_for", pony)
			if not open.is_empty() and bool(appointments.call("cancel", pony, "letter:" + id)): return {"id": str(open.get("id", ""))}
		"relationship_answer":
			var pending: Dictionary = bonds.pending(pony) if bonds != null and bonds.has_method("pending") else {}
			if str(pending.get("kind", "")) in LETTER_ANSWERS: bonds.answer(pony, str(action.get("offer_id", "")), "pony", bool(action.get("accept", false)))
		"ask":
			# Her favour goes in Anon's notebook, open for a day after her reply reaches him.
			var asks := _asks()
			var r := row(id)
			if asks == null or r.is_empty(): return {}
			var hours := (due_after(float(r.get("delivered_at", _now()))) - _now()) * 24.0 + 24.0
			asks.call("create", pony, str(action.get("want", "")), str(action.get("reward", "thanks")), gist.left(120), "letter", hours)
	return {}

## The meeting his letter itself asks for, {"place", "day", "time"} as written, or {}.
func _asked_meeting(r: Dictionary) -> Dictionary:
	return FALLBACK.detect_meet(str(r.text), place_rows(str(r.to))) if _appointments() != null else {}

## Whether her booked meeting is the one he asked for (place, day and time), read against the
## clock when he sent the letter.
static func _same_meeting(asked: Dictionary, booked: Dictionary, sent: float) -> bool:
	if asked.is_empty() or str(booked.get("place", "")) != str(asked.place): return false
	var day := int(floorf(sent))
	var when := MEET_TIME.parse(str(asked.day), str(asked.time), day, (sent - day) * 24.0)
	if not bool(when.ok): return false
	return int(when.day) == int(booked.get("day", -1)) and is_equal_approx(float(when.hour), float(booked.get("hour", -1.0)))

## APPOINTMENTS, before a stood-up: could Anon know of the meeting this letter's reply made? True
## when it is the meeting he asked for, when her reply reached him well before it, or once he took
## her reply from the mailbox.
func meeting_known(letter_id: String) -> bool:
	var r := row(letter_id)
	if r.is_empty() or bool(r.get("meet_known", true)): return true
	return str(row(str(r.get("reply_id", ""))).get("status", "")) in ["taken", "opened"]

## Friendship by score (rude letters cost), romance only from her own tag on a good letter,
## trust for a decent one.
func _effects(pony: String, id: String, score: int, impression: Dictionary, ai: bool) -> void:
	var context := _context()
	var data := {"friendship": SCORING.friendship_for(score)}
	if impression.has("romance") and score >= 60: data.romance = int(impression.romance)
	if impression.has("mood"): data.mood = str(impression.mood)
	elif not ai: data.mood = "happy" if score >= 85 else ("annoyed" if score < 15 else "neutral")
	if impression.has("thought"): data.thought = str(impression.thought)
	var impressions: Node = context.get("impressions")
	if is_instance_valid(impressions) and impressions.has_method("commit"): impressions.commit(pony, data, "letter:" + id)
	var bonds := _bonds()
	if score >= 50 and bonds != null and bonds.has_method("experience"): bonds.experience(pony, "conversation", "letter-" + id)

func _gift(pony: String, id: String, score: int, asked: bool, ai: bool) -> String:
	var give := (asked and score >= 75) or (not ai and score >= 85 and _roll("gift:" + id) < 0.5)
	if not give: return ""
	var pool: Array = GIFTS.filter(func(item: String) -> bool: return CATALOG.has(item))
	return str(pool[absi(hash(pony + id)) % pool.size()]) if not pool.is_empty() else ""

## A lovely or rude letter is worth telling her closest friend in town about.
func _gossip(pony: String, id: String, score: int) -> void:
	if score > 15 and score < 85: return
	var context := _context()
	var population: Variant = game.get("population") if game != null else null
	if not population is Node or not (population as Node).get("live") is Dictionary: return
	var best := ""
	var best_score := 0.0
	for other: Variant in (population as Node).get("live").keys():
		if str(other) == pony: continue
		var rel: Dictionary = context.relationship(pony, str(other))
		var closeness := float(rel.get("familiarity", 0.0)) + float(rel.get("preference", 0.0))
		if closeness > best_score: best = str(other); best_score = closeness
	if best.is_empty(): return
	context.record("gossip", "%s told you Anon wrote her a %s letter." % [display_name(pony), "lovely" if score >= 85 else "rude"],
		[best], [pony, "player"], "letter-gossip:" + id)

## Puts `sentence` before her closing ("Love,\nTwilight"), or at the end.
static func insert_before_sign_off(text: String, sentence: String) -> String:
	var lines := Array(text.strip_edges().split("\n"))
	var at := lines.size()
	if at >= 2 and str(lines[at - 1]).split(" ", false).size() <= 4:
		at -= 1
		if at >= 2 and str(lines[at - 1]).strip_edges().ends_with(",") and str(lines[at - 1]).split(" ", false).size() <= 3: at -= 1
	lines.insert(at, sentence)
	return "\n".join(lines)

# --- Lookups ----------------------------------------------------------------------------------

func display_name(pony: String) -> String:
	if pony == "player": return "Anon"
	var director := _director()
	if director != null and director.get("characters") is Dictionary and (director.characters as Dictionary).has(pony):
		return str(director.characters[pony].profile.get("name", pony))
	var profiles: Dictionary = PROFILES.profiles()
	if profiles.has(pony): return str(profiles[pony].get("name", pony))
	return pony.replace("_", " ").capitalize()

## Her persona text: the registered character's prompt, else her profile's, else one line.
func persona(pony: String) -> String:
	var text := ""
	var director := _director()
	if director != null and director.get("characters") is Dictionary and (director.characters as Dictionary).has(pony):
		text = str(director.characters[pony].get("prompt", ""))
	if text.strip_edges().is_empty():
		var profile: Dictionary = PROFILES.profiles().get(pony, {})
		text = CONFIG.prompt_text(str(profile.get("prompt", "")))
	return PROMPTS.persona_text(text) if not text.strip_edges().is_empty() else "A pony of Ponyville."

## Places she may name for a meeting: town landmarks nearest the town centre first, then her
## home and Anon's. Rows {id, label, her_home, player_home}.
func place_rows(pony: String) -> Array:
	if places_override is Array: return places_override
	if not is_inside_tree(): return []
	var her_home := ""
	var population: Variant = game.get("population") if game != null else null
	if population is Node and (population as Node).has_method("home_house"):
		var house: Node = population.home_house(pony)
		if house != null and house.has_method("place_id"): her_home = str(house.place_id())
	var entries: Array = PLACES.entries(get_tree())
	var centre := Vector3.ZERO
	for e: Dictionary in entries:
		if e.id == "landmark:town_hall": centre = e.position
	var landmarks: Array = []
	var homes: Array = []
	var labels := {}
	for e: Dictionary in entries:
		var mine: bool = str(e.id) == her_home
		var his := bool(e.get("player_home", false))
		if mine or his: homes.append({"id": str(e.id), "label": str(e.label), "her_home": mine, "player_home": his}); continue
		if not str(e.id).begins_with("landmark:") or labels.has(str(e.label)): continue
		labels[str(e.label)] = true
		landmarks.append({"id": str(e.id), "label": str(e.label), "d": centre.distance_squared_to(e.position)})
	landmarks.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a.d) < float(b.d))
	var out: Array = landmarks.slice(0, maxi(0, READER.PLACE_LINES - homes.size())).map(func(p: Dictionary) -> Dictionary: return {"id": p.id, "label": p.label})
	return out + homes

func _memory(pony: String, cue: String) -> String:
	var director := _director()
	var story: RefCounted = director.call("story") if director != null and director.has_method("story") else null
	if story != null: return str(story.context_for(pony, ["player"], cue, true, READER.MEMORY_CHARS))
	var context := _context()
	return str(context.context_for(pony, cue, [], "", READER.MEMORY_CHARS)) if context != null and context.has_method("context_for") else ""

## Her relationship tag context; an open offer a letter cannot answer (LETTER_ANSWERS) is left out.
func _relationship_context(pony: String) -> Dictionary:
	var runtime := _runtime()
	var out: Dictionary = runtime.action_context(pony) if runtime != null and runtime.has_method("action_context") else {"offers": [], "pending": {}}
	var pending: Variant = out.get("pending", {})
	if pending is Dictionary and not (pending as Dictionary).is_empty() and str((pending as Dictionary).get("kind", "")) not in LETTER_ANSWERS:
		out = out.duplicate(); out.pending = {}
	return out

static func _gist(clean: String) -> String:
	var text := clean.replace("\n", " ").strip_edges()
	for opener: String in ["Dear "]:
		if text.begins_with(opener) and text.find(",") > 0 and text.find(",") < 40: text = text.substr(text.find(",") + 1).strip_edges()
	var end := -1
	for mark: String in [". ", "! ", "? "]:
		var at := text.find(mark)
		if at > 0 and (end < 0 or at < end): end = at
	if end > 0: text = text.left(end + 1)
	return text if text.length() <= 160 else text.left(159) + "…"

static func _name_key(text: String) -> String:
	return " ".join(ADDRESSEE._words(text))

static func _roll(seed: String) -> float:
	return float(absi(hash(seed)) % 1000) / 1000.0

static func _clock_text(at: float) -> String:
	var hours := (at - floorf(at)) * 24.0
	return "%02d:%02d" % [int(hours), int(fmod(hours, 1.0) * 60.0)]

func _now() -> float:
	var time: Node = clock if clock != null else (get_node_or_null("/root/TimeOfDay") if is_inside_tree() else null)
	return float(time.get("day")) + float(time.get("hours")) / 24.0 if time != null else 0.0

## The world save in about a second instead of up to ten (a crash right after a send or a new
## draft would otherwise lose the letter the briefcase already saved as gone).
func _save_soon() -> void:
	var context := _context()
	if context != null and context.has_method("save_soon"): context.call("save_soon")

func _context() -> Node:
	if game == null: return null
	var context: Variant = game.get("world_context")
	return context if context is Node and is_instance_valid(context) else null

func _director() -> Node:
	var director: Variant = game.get("director") if game != null else null
	return director if director is Node and is_instance_valid(director) else null

func _bonds() -> Node:
	var context := _context()
	var bonds: Variant = context.get("player_bonds") if context != null else null
	return bonds if bonds is Node and is_instance_valid(bonds) else null

func _runtime() -> Node:
	return get_tree().get_first_node_in_group("player_relationships") if is_inside_tree() else null

func _appointments() -> Node:
	return get_tree().get_first_node_in_group("appointments") if is_inside_tree() else null

func _courier() -> Node:
	return get_tree().get_first_node_in_group("letter_courier") if is_inside_tree() else null

func _asks() -> Node:
	return get_tree().get_first_node_in_group("mechanics_asks") if is_inside_tree() else null
