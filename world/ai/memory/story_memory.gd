extends RefCounted
## What each pony knows, written for the model in plain labelled sections (no JSON): her own
## running summary, her day, what is on her mind, how she feels about the ponies present,
## memories the current words bring up, and what she heard recently. Built from the story
## journal (story_store.gd), which mirrors every world_context event with its witnesses.
## Also owns the incremental summary (PonyPonyParadise style: old summary + only the new lines,
## noise dropped, in bounded batches, only when the story outgrows its budget, with backoff after
## failures), the director brain notes and [feel:] tags.
## Every token sent is paid in full (dev 2026-10-14): sections have hard character budgets.

const STORE := preload("res://world/ai/memory/story_store.gd")
const TOWN_TALK := preload("res://world/ai/memory/town_talk.gd")
const CONTROLS := preload("res://world/ai/speech_controls.gd")
## Running summary (AI tokens 2026-10-22: a 31-minute capture sent 53 identical failing calls,
## 1.33M input tokens, because every reply hit its cap and the failure was resent every 20 s).
## Story text after noise filtering (story_line) may reach this size before a summary call.
const SUMMARY_TRIGGER_CHARS := 6000
## One call covers at most this many ponies and this much new story text, oldest first.
const SUMMARY_BATCH_PONIES := 8
const SUMMARY_BATCH_CHARS := 9000
## Visible reply per pony block (90 words of plain text plus header) and fixed slack. A cap is
## a ceiling, not a charge: only written tokens are billed. 170 per pony cut off wordy models
## (player report 2026-10-31: summaries failed on a hidden length limit, then stopped).
const SUMMARY_TOKENS_PER_PONY := 320
const SUMMARY_TOKENS_BASE := 200
## Extra max_tokens for endpoints that count hidden reasoning inside it (OpenAI-compatible
## proxies in front of thinking models did: 1600 tokens billed, 0-111 characters returned;
## 2048 still ran out on thinking models, so the reply came back empty and cut off).
const SUMMARY_REASONING_ROOM := 6144
## Seconds between calls after progress, and after each consecutive failure (then held; a
## 30-minute hold looked like summaries had stopped for good).
const SUMMARY_MIN_INTERVAL := 45.0
const SUMMARY_BACKOFF := [120.0, 300.0, 600.0]
## A call that never reported back stops blocking new ones after this long.
const SUMMARY_STALE_SECONDS := 300.0
## Stored text per pony summary (the prompt section has its own budget too).
const SUMMARY_TEXT_CHARS := 900
## Command bookkeeping worth remembering once finished; movement and gaze never are.
const MEMORABLE_ACTIONS := ["relationship_offer", "relationship_answer", "request_space", "buck_player", "cuddle",
	"kiss_player", "give_house", "send_letter", "air_show", "sonic_rainboom", "wake_up", "magic_show", "take_off", "put_on",
	"give", "ask", "offer_job", "sell", "buy", "invite"]
## Journal kinds the summary skips: routine bookkeeping (today's routine still reaches prompts
## through day_events), command intentions and private director notes.
const SUMMARY_SKIP_KINDS := ["intention", "brain", "day", "shared_outing", "conversation"]
const BOILERPLATE := [" This was an intention, not proof of completion; active commands do not survive a restart.",
	" This alone does not establish how you felt about it."]
## Recent heard speech kept raw in a prompt.
## 1600 since heard sentences are merged per reply (merged_speech): the same conversation, ~30% fewer characters.
const RECENT_HEARD_CHARS := 1600
const RECENT_HEARD_LINES := 24
## Story notes: <brain> blocks (<story> also accepted; [brain] wrappers are turned into these
## first, speech_controls.gd angle_notes). An unclosed
## block at the very end (cut-off reply) is dropped, never spoken.
const BRAIN_RE := "(?s)<(?:story|brain)>(.*?)</(?:story|brain)>"
const BRAIN_OPEN_RE := "(?s)<(?:story|brain)>.*$"
const FEEL_RE := "\\[feel:\\s*([a-z0-9_]+)\\s*([+-]\\s*[0-9])\\s*\\]"
## Kinds the journal leaves out: one line per spoken line is already "say".
const SKIP_KINDS := ["conversation"]

var store := STORE.new()
var context: Node
var names := Callable()   # id -> display name
var clock := Callable()   # -> {"day": int, "minute": int}
var summarizing := false
## -> seconds (tests drive it); defaults to engine ticks.
var summary_clock := Callable()
var _summary_started := 0.0
var _summary_next_at := 0.0
var _summary_failures := 0
## Halvings of the batch limits after cut-off or failed replies; reset by a complete reply.
var _summary_shrink := 0
var _pending_key := ""
var _pending_chars := 0
var _pending_scanned := 0
var _coverage_version := 0

func open(file_path: String) -> bool:
	return store.open(file_path)

func is_open() -> bool:
	return store.is_open()

func _now() -> Dictionary:
	return clock.call() if clock.is_valid() else {"day": 0, "minute": 0}

func name_of(id: String) -> String:
	if id == "player": return "Anon"
	if id in ["", "none"]: return ""
	var named: Variant = names.call(id) if names.is_valid() else null
	return str(named) if named != null and str(named) != "" else id.replace("_", " ").capitalize()

## world_context.event_recorded: every recorded event, with its witnesses, into the journal.
func mirror(event: Dictionary) -> void:
	if not is_open(): return
	var kind := str(event.get("kind", ""))
	if kind in SKIP_KINDS: return
	var subjects: Array = event.get("subjects", [])
	var now := _now()
	if kind == "heard_speech":
		store.add_line(now.day, now.minute, str(event.get("place", "")), "say", str(subjects[0]) if subjects.size() > 0 else "",
			str(subjects[1]) if subjects.size() > 1 else "", str(event.get("text", "")), event.get("witnesses", []))
	else:
		store.add_line(now.day, now.minute, str(event.get("place", "")), kind, str(subjects[0]) if subjects.size() > 0 else "",
			str(subjects[1]) if subjects.size() > 1 else "", str(event.get("text", "")), event.get("witnesses", []))

static func clock_text(minute: int) -> String:
	return "%02d:%02d" % [int(minute / 60) % 24, minute % 60]

## One journal row as a plain line, from `pony`'s point of view.
func line_text(row: Dictionary, pony: String, with_day := false) -> String:
	var when := clock_text(int(row.minute))
	if with_day: when = "Day %d %s" % [int(row.day) + 1, when]
	var place := str(row.place)
	var at := (" at " + place.replace("_", " ")) if place != "" else ""
	if str(row.kind) == "say":
		var speaker := "You" if str(row.speaker) == pony else name_of(str(row.speaker))
		var listener := str(row.listener)
		var to := ""
		if listener == pony: to = " to you"
		elif listener not in ["", "none"]: to = " to " + name_of(listener)
		return "%s%s, %s%s: \"%s\"" % [when, at, speaker, to, str(row.text)]
	return "%s%s: %s" % [when, at, str(row.text)]

## Pony-to-pony standing as a label (world_context familiarity/trust/preference).
func feeling_label(pony: String, other: String) -> String:
	if not is_instance_valid(context): return ""
	var r: Dictionary = context.relationship(pony, other)
	var preference := float(r.get("preference", 0.0))
	var familiarity := float(r.get("familiarity", 0.0))
	if preference <= -0.6: return "can't stand"
	if preference <= -0.3: return "dislikes"
	if preference <= -0.1: return "finds annoying"
	if familiarity < 0.08 and preference < 0.1: return "barely knows"
	if preference >= 0.6: return "best friend"
	if preference >= 0.3: return "close friend"
	if preference >= 0.1 or familiarity >= 0.3: return "friend"
	return "acquaintance"

## The memory sections for one pony's prompt. `present`: ids around her now; `cue`: the words
## being answered (player text or the topic); `skip_player_chat`: her direct exchange with Anon
## already travels as chat messages, so it is not repeated here.
func context_for(pony: String, present: Array, cue: String, skip_player_chat := true, budget := 4200) -> String:
	if not is_open(): return ""
	var parts: PackedStringArray = []
	var own := store.summary("pony:" + pony)
	if not str(own.text).is_empty():
		parts.append("YOUR STORY SO FAR\n" + str(own.text).strip_edges())
	var now := _now()
	# Gaze and movement bookkeeping ("look_at: completed (t38-0-look_at). Gaze duration finished") and accepted
	# commands ("go_to: accepted (...)", kind intention) are the same noise for her day as for the summary
	# (story_line); current outcomes reach the Situation block.
	var today: Array = store.day_events(pony, int(now.day), 16).filter(func(row): return str(row.kind) != "intention" and (str(row.kind) != "action_outcome" or story_line(row) != ""))
	today = today.slice(maxi(0, today.size() - 10))
	if not today.is_empty():
		parts.append("YOUR DAY SO FAR\n" + "\n".join(today.map(func(row): return line_text(row, pony))))
	# Expired threads stay out, and a save from before the thread dedupe may still hold copies of one
	# want: each thing is listed once, newest wording (player thread report 2026-10-29).
	var mind: Array[String] = []
	var threads := store.open_threads(pony, 6, int(now.day), int(now.minute))
	for i in range(threads.size() - 1, -1, -1):
		var thought := str(threads[i].text)
		if mind.size() < 4 and not mind.any(func(seen: String) -> bool: return STORE.similar(seen, thought)): mind.insert(0, thought)
	if not mind.is_empty():
		parts.append("ON YOUR MIND (anything Anon turned down is settled)\n" + "\n".join(mind.map(func(thought: String) -> String: return "- " + thought)))
	var feelings: PackedStringArray = []
	for other in present:
		var id := str(other)
		if id == pony or id == "player": continue
		var label := feeling_label(pony, id)
		if label != "": feelings.append("%s: %s" % [name_of(id), label])
	if not feelings.is_empty():
		parts.append("HOW YOU FEEL ABOUT THE PONIES HERE\n" + "\n".join(feelings))
	var recent := store.witnessed(pony, RECENT_HEARD_LINES, 0, ["say"])
	if skip_player_chat:
		recent = recent.filter(func(row): return not (str(row.speaker) in [pony, "player"] and str(row.listener) in [pony, "player"]))
	var heard: PackedStringArray = []
	var used := 0
	var spoken := merged_speech(recent)
	for i in range(spoken.size() - 1, -1, -1):
		var line := line_text(spoken[i], pony)
		if used + line.length() > RECENT_HEARD_CHARS: break
		heard.insert(0, line); used += line.length() + 1
	var oldest := int(recent[0].id) if not recent.is_empty() else store.last_line_id() + 1
	var words := _cue_words(cue, present)
	if not words.is_empty():
		# An event already listed under YOUR DAY SO FAR is not repeated as an older memory (PROMPT diet 2026-10-22).
		var listed: Array = today.map(func(row): return int(row.id))
		var found := store.search(pony, words, oldest, 5).filter(func(row): return int(row.id) not in listed)
		if not found.is_empty():
			parts.append("MEMORIES THAT COME TO MIND (older)\n" + "\n".join(found.map(func(row): return line_text(row, pony, true))))
	if not heard.is_empty():
		parts.append("WHAT YOU HEARD RECENTLY (others' conversations included)\n" + "\n".join(heard))
	var text := "\n\n".join(parts)
	return text.left(budget)

## One spoken reply is stored a sentence per line; consecutive lines of the same speaker to the same
## listener at the same place within two minutes read as one quote ("16:25, Pinkie Pie to Anon: "A B C"")
## instead of one timestamped line per sentence (PROMPT diet 2026-10-22: 2.2 KB of heard lines, mostly
## repeated prefixes). Chronological rows in, chronological rows out; stored lines are unchanged.
static func merged_speech(rows: Array) -> Array:
	var merged: Array = []
	for row: Dictionary in rows:
		if not merged.is_empty():
			var last: Dictionary = merged[-1]
			if str(last.speaker) == str(row.speaker) and str(last.listener) == str(row.listener) and str(last.place) == str(row.place) \
					and int(last.day) == int(row.day) and absi(int(row.minute) - int(last.end_minute)) <= 2:
				last.text = str(last.text) + " " + str(row.text)
				last.end_minute = int(row.minute)
				continue
		var copy := row.duplicate()
		copy.end_minute = int(row.minute)
		merged.append(copy)
	return merged

## Search words: names of the ponies present plus the longer words in the cue.
func _cue_words(cue: String, present: Array) -> Array:
	var words: Array = []
	for id in present:
		if str(id) != "player": words.append(name_of(str(id)).to_lower())
	var clean := RegEx.create_from_string("[^a-z0-9' ]").sub(cue.to_lower(), " ", true)
	for word in clean.split(" ", false):
		if word.length() >= 5 and word not in words and word not in ["about", "there", "their", "would", "could", "should", "think", "really", "maybe", "right", "where", "which", "these", "those", "going", "doing", "thing", "anything", "something"]:
			words.append(word)
	return words.slice(0, 8)

# --- Running summary --------------------------------------------------------------------------

const SUMMARY_SYSTEM := """You keep the memory of a pony life game. The player is Anon. Update the private story summary of each pony listed under PONIES with the new events.
Events are grouped under [Known to: ...]; each pony knows ONLY the events in groups that name her. Never put something into a pony's summary she did not witness or was not told. "You" in an event means each pony it is known to.
Write one block per listed pony, in this exact layout, plain text, no JSON, no markdown, no preamble:
PONY pony_id
Anon: how she sees him now, in a few words (if she has met him)
Encounters: 1-3 sentences on what happened between them
Notable moments: short list separated by semicolons (promises, secrets, firsts, fights, gifts)
Others: who else matters to her lately and why, one short sentence
Future hooks: what she wants or plans next, one short sentence
Keep each pony under 90 words. Merge her previous summary with the new events; keep what still matters, drop trivia, keep exact names, places and real promises. Drop bets, dares and running jokes once settled, stale for days or repeating without progress; never let one topic dominate."""

func _covered() -> int:
	return int(store.summary("through").through)

func _seconds() -> float:
	return float(summary_clock.call()) if summary_clock.is_valid() else Time.get_ticks_msec() / 1000.0

## One non-speech journal row as summary input, or "" when it is noise for long-term memory.
func story_line(row: Dictionary) -> String:
	var kind := str(row.kind)
	if kind in SUMMARY_SKIP_KINDS: return ""
	var text := str(row.text).strip_edges()
	if kind == "action_outcome":
		# "type: status (id). reason" (director_contacts.gd _remember_outcome).
		var type := text.get_slice(":", 0).strip_edges()
		var status := text.get_slice(":", 1).strip_edges().get_slice(" ", 0)
		if type not in MEMORABLE_ACTIONS or status not in ["completed", "failed"]: return ""
		var cut := text.find("). ")
		var reason := text.substr(cut + 3).strip_edges() if cut >= 0 else ""
		return "%s %s%s" % [type.replace("_", " "), status, (": " + reason) if reason != "" else ""]
	if kind == "shared_player_activity" and text == "You and Anon completed conversation together.": return ""
	for words: String in BOILERPLATE: text = text.replace(words, "")
	return text

## Oldest-first slice of the story not yet in every witness's summary. Rows whose pony
## witnesses are all covered and noise rows are skipped (they still count as covered), speech
## runs merge into one line, repeats are counted once, and "Known to" is written only when it
## changes. Stops before the row that would exceed `max_ponies` or `max_chars`.
## {lines, ponies, chars, through, settled}: settled = end of the leading run needing nothing.
func _story_batch(max_ponies: int, max_chars: int) -> Dictionary:
	var start := _covered()
	var batch := {"lines": [], "ponies": [], "chars": 0, "through": start, "settled": start}
	var rows := _story_rows(start)
	if rows.is_empty(): return batch
	var lines: Array[String] = []
	var counts: Array[int] = []
	var repeats: Dictionary = {}
	var involved: Dictionary = {}
	var header := ""
	var day := -1
	var place := ""
	var say_key := ""
	var used := 0
	for row: Dictionary in rows:
		var id := int(row.id)
		var witnesses: Array = row.witness_list
		var fresh: Array = row.fresh
		var kind := str(row.kind)
		var text := str(row.story)
		if text == "":
			batch.through = id
			if lines.is_empty(): batch.settled = id
			continue
		var group := "[Known to: %s]" % ", ".join(witnesses.map(func(w): return name_of(str(w))))
		var prefix: Array[String] = []
		if int(row.day) != day: prefix.append("Day %d" % (int(row.day) + 1))
		if group != header or not prefix.is_empty(): prefix.append(group)
		var at := str(row.place)
		var key := "%s|%s|%s|%s" % [row.speaker, row.listener, group, at] if kind == "say" else ""
		var merge := kind == "say" and key == say_key and prefix.is_empty()
		var piece := text
		if kind == "say":
			piece = "\"%s\"" % text
			if merge: piece = " " + piece
			else:
				var to := str(row.listener)
				piece = "%s%s%s: %s" % [name_of(str(row.speaker)), (" to " + name_of(to)) if to not in ["", "none"] else "",
					(" at " + at.replace("_", " ")) if at != "" and at != place else "", piece]
		elif prefix.is_empty() and repeats.has(text):
			counts[int(repeats[text])] += 1
			batch.through = id
			continue
		var adds := fresh.filter(func(w): return not involved.has(w)).size()
		var cost := piece.length() + 1
		for p: String in prefix: cost += p.length() + 1
		if not lines.is_empty() and (involved.size() + adds > max_ponies or used + cost > max_chars): break
		if not prefix.is_empty(): repeats.clear()
		for p: String in prefix:
			lines.append(p); counts.append(1)
		if merge: lines[lines.size() - 1] += piece
		else:
			lines.append(piece); counts.append(1)
			if kind != "say": repeats[text] = lines.size() - 1
		for w in fresh: involved[w] = true
		day = int(row.day); header = group; say_key = key
		if kind == "say" and at != "": place = at
		used += cost
		batch.through = id
	for i in lines.size():
		if counts[i] > 1: lines[i] += " (%d times)" % counts[i]
	batch.lines = lines
	batch.ponies = involved.keys()
	batch.chars = used
	return batch

## True when enough unsummarized story (after noise filtering) waits, no call is in flight and
## the pause after the last call (longer after each failure) is over.
func needs_summary(trigger_chars := SUMMARY_TRIGGER_CHARS) -> bool:
	if not is_open(): return false
	var now := _seconds()
	if summarizing:
		if now - _summary_started < SUMMARY_STALE_SECONDS: return false
		summarizing = false
	if now < _summary_next_at: return false
	# Counted incrementally: only lines added since the last check are read (every 5 s).
	var key := "%d:%d" % [_covered(), _coverage_version]
	var last := store.last_line_id()
	# A rollback (older save loaded) can remove counted lines; ids are then reused.
	if key != _pending_key or last < _pending_scanned:
		_pending_key = key; _pending_chars = 0; _pending_scanned = _covered()
	while _pending_scanned < last:
		var rows := _story_rows(_pending_scanned, 2000)
		if rows.is_empty(): break
		for row: Dictionary in rows:
			if str(row.story) != "": _pending_chars += str(row.story).length() + 30
		_pending_scanned = int(rows[-1].id)
	return _pending_chars >= trigger_chars

## Journal rows after `after` (oldest first) with witness_list (sorted), fresh (pony witnesses
## whose summary does not cover the row yet) and story (summary text; "" = skip it: noise, or
## every pony witness already covered). Speech keeps its bare words; _story_batch formats it.
func _story_rows(after: int, limit := 4000) -> Array:
	var rows := store.lines_after(after, limit)
	if rows.is_empty(): return rows
	var witnesses_of: Dictionary = {}
	for w: Dictionary in store._rows("SELECT line, pony FROM witnesses WHERE line > ? AND line <= ?;", [after, int(rows[-1].id)]):
		if not witnesses_of.has(int(w.line)): witnesses_of[int(w.line)] = []
		witnesses_of[int(w.line)].append(str(w.pony))
	var covered: Dictionary = {}
	for s: Dictionary in store._rows("SELECT key, through FROM summary WHERE key LIKE 'pony:%';"):
		covered[str(s.key).trim_prefix("pony:")] = int(s.through)
	for row: Dictionary in rows:
		var id := int(row.id)
		var witnesses: Array = witnesses_of.get(id, [])
		witnesses.sort()
		var fresh: Array = witnesses.filter(func(w): return w != "player" and int(covered.get(w, 0)) < id)
		row.witness_list = witnesses
		row.fresh = fresh
		row.story = "" if fresh.is_empty() else (str(row.text).strip_edges() if str(row.kind) == "say" else story_line(row))
	return rows

## {system, user, through, settled, ponies, output_tokens, reasoning_room, store} for one
## bounded summary call, or {} when nothing new. Batches shrink after cut-off or failed replies.
func summary_request(max_chars := SUMMARY_BATCH_CHARS) -> Dictionary:
	var batch := _story_batch(maxi(1, SUMMARY_BATCH_PONIES >> _summary_shrink), maxi(1500, max_chars >> _summary_shrink))
	if (batch.lines as Array).is_empty():
		# Only noise or covered rows (a long run fills a whole read): move the mark past them.
		if int(batch.through) > _covered(): store.set_summary("through", "", int(batch.through)); _coverage_version += 1
		return {}
	_summary_started = _seconds()
	var ponies: Array = batch.ponies
	var previous: PackedStringArray = []
	for pony: String in ponies:
		var old := str(store.summary("pony:" + pony).text)
		if old != "": previous.append("PONY %s\n%s" % [pony, old])
	var user := "PONIES\n%s\n\nPREVIOUS SUMMARIES\n%s\n\nNEW EVENTS\n%s" % [", ".join(ponies.map(func(p): return "%s (%s)" % [p, name_of(str(p))])),
		"\n\n".join(previous) if not previous.is_empty() else "(none yet)", "\n".join(PackedStringArray(batch.lines))]
	return {"system": SUMMARY_SYSTEM, "user": user, "through": int(batch.through), "settled": int(batch.settled), "ponies": ponies,
		"output_tokens": SUMMARY_TOKENS_BASE + SUMMARY_TOKENS_PER_PONY * ponies.size(), "reasoning_room": SUMMARY_REASONING_ROOM, "store": store.path}

## The summary call came back (llm_client callback: text, error). Stores every complete pony
## block (also from a cut-off reply), then waits SUMMARY_MIN_INTERVAL after progress or the
## next SUMMARY_BACKOFF step after a call that stored nothing. Returns ponies updated.
func finish_summary(text: String, error: String, request: Dictionary) -> int:
	summarizing = false
	if not is_open() or str(request.get("store", store.path)) != store.path: return 0
	var complete := error == ""
	var stored := apply_summary(text, int(request.get("through", 0)), request, complete) if not text.strip_edges().is_empty() else 0
	if stored > 0:
		_summary_failures = 0
		_summary_shrink = 0 if complete else mini(_summary_shrink + 1, 2)
		_summary_next_at = _seconds() + SUMMARY_MIN_INTERVAL
	else:
		_summary_failures += 1
		_summary_shrink = mini(_summary_shrink + 1, 2)
		_summary_next_at = _seconds() + float(SUMMARY_BACKOFF[mini(_summary_failures, SUMMARY_BACKOFF.size()) - 1])
	return stored

static func _summary_key(text: String) -> String:
	return text.strip_edges().to_lower().replace(".", "").replace("'", "").replace(" ", "_")

## Stores the model's pony blocks; returns how many it updated. With a request, only its ponies
## are accepted (by id or name). `complete`: the reply was not cut off, so its last block counts
## and listed ponies the model left out keep their summary but are covered too. A cut-off reply
## keeps its finished blocks only and moves no pony it did not write.
func apply_summary(text: String, through: int, request: Dictionary = {}, complete := true) -> int:
	var wanted: Dictionary = {}
	for pony in request.get("ponies", []):
		wanted[_summary_key(str(pony))] = str(pony)
		wanted[_summary_key(name_of(str(pony)))] = str(pony)
	var blocks: Array = []
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		var bare := line.lstrip("*#> ").strip_edges()
		if bare.begins_with("PONY ") or bare.begins_with("PONY:"):
			blocks.append([bare.trim_prefix("PONY").lstrip(": ").rstrip("*: ").strip_edges(), []])
		elif not blocks.is_empty() and line != "":
			blocks[-1][1].append(line)
	if not complete and not blocks.is_empty() and not _block_finished(blocks[-1][1]): blocks.pop_back()
	var stored: Dictionary = {}
	for block: Array in blocks:
		# Headers may copy the PONIES entry "id (Name)": match the id, else the bracketed name.
		var header := str(block[0])
		var key := _summary_key(header.get_slice(" (", 0))
		if not wanted.is_empty() and not wanted.has(key) and header.contains("("): key = _summary_key(header.get_slice("(", 1).get_slice(")", 0))
		var pony := str(wanted.get(key, "")) if not wanted.is_empty() else key
		if pony == "" or stored.has(pony) or (block[1] as Array).is_empty(): continue
		store.set_summary("pony:" + pony, "\n".join(PackedStringArray(block[1])).left(SUMMARY_TEXT_CHARS), through)
		stored[pony] = true
	if stored.is_empty(): return 0
	var ponies: Array = request.get("ponies", [])
	# Left-out ponies count as covered only when most blocks matched (else headers went wrong).
	complete = complete and stored.size() * 2 >= ponies.size()
	if complete:
		for pony in ponies:
			if not stored.has(str(pony)): store.set_summary("pony:" + str(pony), str(store.summary("pony:" + str(pony)).text), through)
	if complete or stored.size() >= ponies.size(): store.set_summary("through", "", through)
	elif int(request.get("settled", 0)) > _covered(): store.set_summary("through", "", int(request.settled))
	_coverage_version += 1
	return stored.size()

## A block from a cut-off reply counts only when its last line finished the layout.
static func _block_finished(body: Array) -> bool:
	if body.is_empty(): return false
	var last := str(body[-1])
	return last.begins_with("Future hooks:") and last.right(1) in [".", "!", "?", "\"", ")"]

# --- Director brain and feelings ----------------------------------------------------------------

## Planning notes ahead of the spoken reply. Providers may refuse this now and then (Opus did on
## 2026-10-15); the client simply retries. Never soften the prompt for one provider (dev 2026-10-15).
## NEXT once said "make it happen in this reply or the next" and weak models invented off-screen
## events; DONE closes threads (player thread report 2026-10-29). ELSEWHERE picks from the TOWN NOW
## line (town_note(), town_talk.gd) instead of inventing town events (thread report 2026-11-03).
const BRAIN_INSTRUCTION := """DIRECTOR NOTES (required this turn): start your reply with a private <brain>...</brain> block, plain text, at most 60 words, nobody hears it:
WANT pony_id: what this pony wants right now, apart from Anon, never something Anon turned down (one line per pony present)
ELSEWHERE: one true thing a pony under TOWN NOW is doing, as town talk in your own words; skip it when none is listed
NEXT: one likely thing that could happen soon, grounded in who and what is here now; never an event about a pony or thing not present
DONE: what is settled, dropped, turned down by Anon or no longer matters (optional)
Setbacks must be fair: foreshadowed or the result of earlier facts. After </brain>, write the normal reply."""

## Anon turning down what she asked for settles it at once: her wants that share two or more words with
## her last line plus his answer close. A want otherwise stays ON YOUR MIND for a day unless a notes
## turn writes DONE, and Twilight asked him to draw a helicopter again after every no (player report
## 2026-10-30). A wrong close only drops a want; the next notes turn can open it again.
const DECLINE_RE := "(?i)\\b(no|nope|nah|refuse|won'?t|not (going to|gonna|doing)|stop (asking|it)|quit asking|forget (it|about)|drop it|enough|never)\\b"
func declined(pony: String, asked: String, answer: String) -> int:
	if not is_open() or asked.strip_edges().is_empty(): return 0
	if RegEx.create_from_string(DECLINE_RE).search(answer) == null: return 0
	var said := STORE.thread_words(asked + " " + answer)
	var closed := 0
	for thread: Dictionary in store.open_threads(pony, 12):
		var shared := 0
		for word: String in STORE.thread_words(str(thread.text)):
			if said.has(word): shared += 1
		if shared >= 2: _settle(int(thread.id)); closed += 1
	return closed

## A topic Anon turned down or a DONE note settled stays settled for SETTLED_MINUTES, and a topic that
## already had its day on her mind (story_store.gd THREAD_LIFE_MINUTES from its first opening) rests as
## long: the same WANT or NEXT written again meanwhile is not reopened. Before this, every notes turn
## could reopen it, so a refused helicopter drawing came back after every no and stale wants returned
## each day (player threads 43665659, 43670743, 2026-10-29/30).
const SETTLED_MINUTES := 2 * 1440

## Closes a thread as settled: `closed` holds 2 + the journal line id it was settled at (0 is open,
## 1 faded out), so the settling time can be read back; every reader only tests closed = 0.
func _settle(id: int) -> void:
	store._run("UPDATE threads SET closed = ? WHERE id = ?;", [2 + store.last_line_id(), id])

## True when this pony's `text` is a settled or spent topic (SETTLED_MINUTES) and must not reopen.
func settled_topic(pony: String, text: String) -> bool:
	if not is_open(): return false
	var now := _now()
	var at := int(now.day) * 1440 + int(now.minute)
	var life := STORE.THREAD_LIFE_MINUTES
	var rows := store._rows("SELECT threads.text AS text, threads.closed AS closed, o.day * 1440 + o.minute AS opened_at, s.day * 1440 + s.minute AS settled_at"
		+ " FROM threads LEFT JOIN lines o ON o.id = threads.opened LEFT JOIN lines s ON threads.closed >= 2 AND s.id = threads.closed - 2"
		+ " WHERE threads.pony = ? AND ((threads.closed >= 2 AND s.day * 1440 + s.minute > ?) OR (o.day * 1440 + o.minute > ? AND o.day * 1440 + o.minute < ?));",
		[pony, at - SETTLED_MINUTES, at - life - SETTLED_MINUTES, at - life])
	for row: Dictionary in rows:
		if STORE.similar(str(row.text), text): return true
	return false

## Strips story notes from a reply, storing them. Returns the cleaned reply. Square wrappers
## ([brain]...[/brain], [story]; GitHub PR #13) count as the angle ones.
func take_notes(text: String, speaker: String, present: Array) -> String:
	text = CONTROLS.angle_notes(text)
	var brain := RegEx.create_from_string(BRAIN_RE)
	var found := brain.search(text)
	if found != null:
		text = brain.sub(text, "", true).strip_edges()
		_store_brain(found.get_string(1), speaker, present, text)
	return RegEx.create_from_string(BRAIN_OPEN_RE).sub(text, "", false).strip_edges()

## The TOWN NOW line for a notes turn (town_talk.gd), or "": real off-screen ponies and finished day
## steps, leaving out ponies the last rumours already named.
func town_note(tree: SceneTree, present: Array) -> String:
	if not is_open() or tree == null: return ""
	var rumours: Array = store.lines_of_kinds(["rumour"], TOWN_TALK.RECENT_RUMOURS).map(func(row): return str(row.text))
	var now := _now()
	var events: Array = store.lines_of_kinds(["day"], 8).filter(func(row): return int(row.day) * 1440 + int(row.minute) >= int(now.day) * 1440 + int(now.minute) - TOWN_TALK.SAME_PONY_MINUTES)
	return TOWN_TALK.town_now(tree, present, rumours, events, name_of, int(now.day) * 1440 + int(now.minute))

## A rumour from a notes turn, or why not (town_talk.gd reject): stored as hearsay for the speaker.
func _store_rumour(text: String, speaker: String, reply: String) -> void:
	var now := _now()
	var said: Array = store.witnessed(speaker, 12, 0, ["say"]).map(func(row): return str(row.text))
	if not reply.is_empty(): said.append(reply)
	var why := TOWN_TALK.reject(text, store.lines_of_kinds(["rumour"], TOWN_TALK.RECENT_RUMOURS), said, now)
	if not why.is_empty():
		print("[story] rumour skipped (%s): %s" % [why, text.left(120)])
		return
	store.add_line(now.day, now.minute, "", "rumour", "", "", TOWN_TALK.PREFIX + text, [speaker])

func _store_brain(note: String, speaker: String, present: Array, reply := "") -> void:
	if not is_open(): return
	var now := _now()
	store.add_line(now.day, now.minute, "", "brain", speaker, "", note.strip_edges(), [speaker])
	# DONE first: it settles older threads of the ponies this note speaks for, never this note's own
	# WANT/NEXT ("DONE pony_id: ..." also accepted; player thread report 2026-10-29).
	for raw in note.split("\n"):
		var line := raw.strip_edges()
		if not line.begins_with("DONE") or line.find(":") < 0: continue
		var settled := line.substr(line.find(":") + 1).strip_edges()
		if settled.is_empty(): continue
		var owners: Array = [speaker]
		for id in present:
			if str(id) not in owners and str(id) != "player": owners.append(str(id))
		for pony: String in owners:
			for thread: Dictionary in store.open_threads(pony, 12):
				if STORE.similar(str(thread.text), settled): _settle(int(thread.id))
	for raw in note.split("\n"):
		var line := raw.strip_edges()
		if line.begins_with("WANT "):
			var rest := line.trim_prefix("WANT ")
			var colon := rest.find(":")
			if colon <= 0: continue
			var pony := rest.left(colon).strip_edges().to_lower()
			if pony in present or pony == speaker: _open_thread(pony, "You want: " + rest.substr(colon + 1).strip_edges())
		elif line.begins_with("NEXT:"):
			_open_thread(speaker, "Soon: " + line.trim_prefix("NEXT:").strip_edges())
		elif line.begins_with("ELSEWHERE:"):
			_store_rumour(line.trim_prefix("ELSEWHERE:").strip_edges(), speaker, reply)

func _open_thread(pony: String, text: String) -> void:
	if settled_topic(pony, text):
		print("[story] %s: settled topic not reopened: %s" % [pony, text.left(100)])
		return
	store.add_thread(pony, text, store.last_line_id())

## Applies and removes [feel: pony_id +1] tags (speaker's feeling toward another pony).
func take_feelings(text: String, speaker: String) -> String:
	var feel := RegEx.create_from_string(FEEL_RE)
	for match in feel.search_all(text):
		var other := match.get_string(1)
		var amount := clampi(int(match.get_string(2).replace(" ", "")), -3, 3)
		if is_instance_valid(context) and other != speaker and other != "player" and amount != 0:
			var r: Dictionary = context.relationship(speaker, other)
			context.set_relationship(speaker, other, float(r.familiarity) + 0.02, float(r.trust) + amount * 0.03, float(r.preference) + amount * 0.06)
	return feel.sub(text, "", true).strip_edges()

const FEEL_INSTRUCTION := "If this exchange changed how a speaker feels about ANOTHER PONY present (not Anon), add [feel: pony_id +1] or [feel: pony_id -1] to that speaker's line (+2/-2 for big moments). Most lines need none."

func record_usage(kind: String, usage: Dictionary) -> void:
	if not is_open() or usage.is_empty(): return
	# OpenAI-style prompt_tokens include cached ones; Anthropic's input_tokens exclude cache reads and
	# writes, which it reports beside them.
	var cached := int(usage.get("cache_read_input_tokens", usage.get("cached_tokens", 0)))
	var input := int(usage.prompt_tokens) if usage.has("prompt_tokens") else int(usage.get("input_tokens", 0)) + int(usage.get("cache_read_input_tokens", 0)) + int(usage.get("cache_creation_input_tokens", 0))
	var output := int(usage.get("completion_tokens", usage.get("output_tokens", 0)))
	var now := _now()
	store.add_usage(kind, input, output, now.day, now.minute, cached)
