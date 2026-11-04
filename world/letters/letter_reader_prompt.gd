extends RefCounted
## The one AI call a delivered letter costs (docs/LETTERS_PLAN_2026_10_29.md section 6): who she
## is, how she stands with Anon, what she remembers, today, the places she can name, then the
## task. One reply gives her heart score, her decisions as action tags and her reply letter.
## Tokens are paid in full on every call (no caching assumed): the system prompt stays under
## SYSTEM_BYTES and the letter under USER_BYTES, about 1,900 input tokens together.
const SCHEMA := preload("res://world/ai/pony_action_schema.gd")
const LETTER_TEXT := preload("res://world/letters/letter_text.gd")
const LIMITS := {"purpose": "letter_read", "input_bytes": 8192, "output_tokens": 450, "reasoning_room": 512}
const SYSTEM_BYTES := 4800
const USER_BYTES := 2600
const PERSONA_CHARS := 1400
const LINE_CHARS := 500
const MEMORY_CHARS := 900
const PLACE_LINES := 24
## No relationship_offer: player_bonds.gd offers expire after 180 real seconds, long before he reads
## her reply the next morning, so an offer made in a letter would quietly lapse unseen. She can
## invite him in her words; the offer itself is made when they next talk.
## relationship_answer only for his open offers that make no timed plan (letter_post.gd LETTER_ANSWERS).
const CAPABILITIES := ["meet", "meet_cancel", "relationship_answer"]
## Only while she has room for a favour (world/mechanics/asks/asks.gd letter_context): one line.
const FAVOUR := "Optional, only if you really need his help: [ask: WANT, REWARD] ask him a favour (2 apples, fetch PONY, go to PLACE_ID or help at JOB; REWARD bits you hold or thanks), and ask it in the letter too."
const TASK := """Anon sent you this letter by Derpy's post. Read it as yourself, decide, and write back.
Start with tags only, one per line:
[heart: 0-100] how much it touched you: kind, personal, about your interests and what you two shared = high; careless or rude = low
[gist: one line saying what he wrote or asked]
Optional: [romance: -2..2] [mood: NAME] [thought: short private thought] [gift] (tuck a small gift in)
Only if the letter asks for it: [meet: PLACE_ID, today|tomorrow|N, HH:MM] agree to meet him (or name another time you prefer),
[meet_cancel] call off your meeting, [relationship_answer: OFFER_ID, yes|no]
Then a line with --- and your reply letter, 40-160 words, in your own voice, starting "Dear Anon," and signed with your name.
If you agree to meet, say where and when in the letter; he reads it tomorrow morning (right away if you meet before then), so name the day clearly. Never mention scores or tags."""

## `parts`: name, persona, standing, bonds, memory, today, appointment, offer, places ([[id, label]]).
## Optional parts that are empty are left out.
static func system_prompt(parts: Dictionary) -> String:
	var persona := _clip(str(parts.get("persona", "")), PERSONA_CHARS)
	# Persona files already open with "You are <Name>."
	var head := persona if persona.to_lower().begins_with("you are") else "You are %s. %s" % [str(parts.get("name", "a pony")), persona]
	var lines: PackedStringArray = [head.strip_edges()]
	for key: String in ["standing", "bonds"]:
		var line := _clip(str(parts.get(key, "")).replace("\n", " "), LINE_CHARS)
		if not line.is_empty(): lines.append(line)
	var today := str(parts.get("today", ""))
	for key: String in ["appointment", "offer", "favour"]:
		var extra := str(parts.get(key, "")).strip_edges()
		if not extra.is_empty(): today += "\n" + extra
	var places: PackedStringArray = []
	for row: Variant in parts.get("places", []):
		if places.size() >= PLACE_LINES: break
		if row is Array and (row as Array).size() >= 2: places.append("%s = %s" % [row[0], row[1]])
	var tail := today.strip_edges() + "\nPLACES (id = name):\n" + ("\n".join(places) if not places.is_empty() else "(none)") + "\n\n" + TASK
	var memory := _clip(str(parts.get("memory", "")), MEMORY_CHARS)
	var prompt := _join(lines, memory, tail)
	# Over budget (a long persona or record): the memory shrinks first, then the persona.
	while prompt.to_utf8_buffer().size() > SYSTEM_BYTES and memory.length() > 0:
		memory = memory.left(maxi(0, memory.length() - 200))
		prompt = _join(lines, memory, tail)
	while prompt.to_utf8_buffer().size() > SYSTEM_BYTES and lines[0].length() > 80:
		lines[0] = lines[0].left(lines[0].length() - 200)
		prompt = _join(lines, memory, tail)
	return prompt

static func user_message(text: String, stationery: String, day: int, hours: float) -> String:
	var head := "LETTER (stationery: %s, day %d %02d:%02d):\n" % [stationery, day, int(hours), int(fmod(hours, 1.0) * 60.0)]
	var body: String = LETTER_TEXT.for_reader(text)
	while (head + body).to_utf8_buffer().size() > USER_BYTES and body.length() > 0:
		body = body.left(body.length() - 100)
	return head + body

## The reply split at its first "---" line: {"heart", "gist", "gift", "impression", "actions",
## "reply", "dropped"}. A missing heart is 50; a missing letter is "" (the caller writes the
## fallback reply). `context` is the decode_tags context (capabilities, locations, labels, relationship).
static func parse(reply: String, context: Dictionary) -> Dictionary:
	var tag_part := reply
	var letter := ""
	var lines := reply.replace("\r", "").split("\n")
	for i in lines.size():
		if lines[i].strip_edges() == "---":
			tag_part = "\n".join(lines.slice(0, i)); letter = "\n".join(lines.slice(i + 1)).strip_edges()
			break
	if letter.is_empty() and tag_part == reply:
		# No separator: leading lines that hold only tags are the tags, the rest the letter.
		var at := 0
		while at < lines.size() and (lines[at].strip_edges().is_empty() or _only_tags(lines[at])): at += 1
		tag_part = "\n".join(lines.slice(0, at)); letter = "\n".join(lines.slice(at)).strip_edges()
	var heart := 50
	var found := _regex("\\[\\s*heart\\s*[:=]\\s*(\\d{1,3})").search(tag_part)
	if found != null: heart = clampi(found.get_string(1).to_int(), 0, 100)
	found = _regex("\\[\\s*gist\\s*[:=]\\s*([^\\]\\n]*)\\]").search(tag_part)
	var gist := found.get_string(1).strip_edges().left(160) if found != null else ""
	var gift := _regex("\\[\\s*gift\\s*(?:[:=]\\s*(?:yes|true|1)\\s*)?\\]").search(tag_part) != null
	var own := _regex("\\[\\s*(heart|gist|gift)\\b[^\\]\\n]*\\]")
	var tags := own.sub(tag_part, "", true)
	letter = _strip_tags(letter)
	var decoded: Dictionary = SCHEMA.decode_tags(tags + "\n" + letter, "letter", 0, context)
	var actions: Array = decoded.get("actions", []) if not decoded.has("error") else []
	return {"heart": heart, "gist": gist, "gift": gift, "impression": decoded.get("impression", {}),
		"actions": actions, "dropped": decoded.get("dropped", []), "reply": letter}

## The places a model may name for [meet], as decode_tags locations and labels; `clock`
## ({day, hours}) is the game time a meeting day and time are read against.
static func decode_context(places: Array, relationship: Dictionary, clock: Dictionary) -> Dictionary:
	var ids: Array = []
	var labels := {}
	for row: Variant in places:
		if row is Array and (row as Array).size() >= 2:
			ids.append(str(row[0])); labels[str(row[0])] = str(row[1])
	return {"capabilities": CAPABILITIES.duplicate(), "targets": {}, "locations": ids, "place_labels": labels, "relationship": relationship, "clock": clock}

static func _join(lines: PackedStringArray, memory: String, tail: String) -> String:
	var text := "\n".join(lines)
	if not memory.strip_edges().is_empty(): text += "\nWhat you remember:\n" + memory.strip_edges()
	return text + "\n" + tail

static func _only_tags(line: String) -> bool:
	return _regex("^\\s*(\\[[^\\]\\n]*\\]\\s*)+$").search(line) != null

## A reply letter never shows tags (face, gesture or stray action tags).
static func _strip_tags(text: String) -> String:
	var out := _regex("\\[[^\\]\\n]{0,80}\\]").sub(text, "", true)
	return _regex("[ \\t]{2,}").sub(out, " ", true).strip_edges()

static func _clip(text: String, limit: int) -> String:
	var t := text.strip_edges()
	return t if t.length() <= limit else t.left(limit - 1).strip_edges() + "…"

static func _regex(pattern: String) -> RegEx:
	var r := RegEx.new()
	r.compile(pattern)
	return r
