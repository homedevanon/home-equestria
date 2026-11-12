extends RefCounted
## What the journal page (world/ui/journal_page.gd) shows of a world: its story journal
## (world/ai/memory/story_store.gd) read back as entries, a reply each or a notable moment, gathered
## into scenes. Dev 2026-10-28: "export in PNG format to show other our discussions/adventures",
## recent or older lines, one pony or a group. Read only; the game keeps writing the journal while
## the page reads its own connection.
const STORE := preload("res://world/ai/memory/story_store.gd")
const MEMORY := preload("res://world/ai/memory/story_memory.gd")
const CATALOGUE := preload("res://world/saves/save_catalogue.gd")
const PONY_DATA := preload("res://world/ui/pony_map_data.gd")
const AI_CONFIG := preload("res://world/ai/ai_config.gd")
## Kinds read back: speech, and the events that can make a moment (moment_text).
const KINDS := ["say", "arrival", "rumour", "action_outcome"]
## The newest journal lines read; older ones are left out of the page.
const MOST_LINES := 20000
## A pause this long (game minutes), a new day or a new place starts another scene.
const SCENE_GAP := 25
## Finished commands worth a line in the story: what to write, {a} the pony, {p} the player.
## "Completed" is not always what it sounds like: a declined invitation completes too, so
## relationship offers and answers are left out.
const MOMENTS := {
	"sonic_rainboom": "{a} pulled off a Sonic Rainboom!", "air_show": "{a} put on an air show.",
	"kiss_player": "{a} kissed {p}.", "cuddle": "{a} cuddled up to {p}.", "buck_player": "{a} bucked {p}!",
	"give_house": "{a} gave {p} a house.", "send_letter": "{a} sent a letter to Princess Celestia.", "wake_up": "{a} woke up.", "pay_player": "{a} paid {p} some bits.",
	"give": "{a} gave {p} something.", "ask": "{a} asked {p} for a favour.", "offer_job": "{a} offered {p} work.",
	"invite": "{a} invited {p} to a town event.", "sell": "{a} offered {p} a deal.", "buy": "{a} bought something from {p}.",
}
const OUTCOME := "^([a-z_]+): completed \\([^)]*\\)\\.\\s*(.*)$"
const PLAYER := "player"
## Listeners that are nopony in particular.
const NOBODY := ["", "none", "all", "everyone"]


## {entries, scenes, ponies: [{id, name, lines}] most lines first, days: [int], player, error}.
static func read_world(root: String, id: String) -> Dictionary:
	var result := {"entries": [], "scenes": [], "ponies": [], "days": [], "player": player_name(), "error": ""}
	var path := root.path_join(id).path_join("story.db")
	if not FileAccess.file_exists(path):
		result.error = "No story journal yet." if STORE.available() else "The story journal needs the SQLite addon."
		return result
	var store := STORE.new()
	if not store.open(path):
		result.error = "The story journal could not be opened: " + store.error
		return result
	var rows := store.lines_of_kinds(KINDS, MOST_LINES)
	store.close()
	result.entries = entries_of(rows, result.player)
	result.scenes = scenes_of(result.entries)
	var counts := {}
	var days := {}
	for entry: Dictionary in result.entries:
		days[int(entry.day)] = true
		if entry.kind == "say" and str(entry.speaker) != PLAYER: counts[entry.speaker] = int(counts.get(entry.speaker, 0)) + 1
	for pony: String in counts: result.ponies.append({"id": pony, "name": name_of(pony, result.player), "lines": counts[pony]})
	result.ponies.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.lines) > int(b.lines) or (int(a.lines) == int(b.lines) and str(a.name) < str(b.name)))
	result.days = days.keys(); result.days.sort()
	return result


## Journal rows as entries: a spoken reply (its sentences merged, as the prompts read them) or a
## moment. {id, day, minute, end_minute, place, kind: "say" | "moment", speaker, listener, text}.
static func entries_of(rows: Array, player := "Anon") -> Array:
	var speech: Array = []
	var entries: Array = []
	var outcome := RegEx.create_from_string(OUTCOME)
	for row: Dictionary in rows:
		if str(row.kind) == "say":
			speech.append(row); continue
		entries.append_array(_said(speech)); speech.clear()
		var text := moment_text(row, player, outcome)
		if text.is_empty(): continue
		entries.append({"id": int(row.id), "day": int(row.day), "minute": int(row.minute), "end_minute": int(row.minute),
			"place": str(row.place), "kind": "moment", "speaker": str(row.speaker), "listener": str(row.listener), "text": text})
	entries.append_array(_said(speech))
	return entries


static func _said(rows: Array) -> Array:
	var said: Array = []
	for row: Dictionary in MEMORY.merged_speech(rows):
		var text := str(row.text).strip_edges()
		if text.is_empty(): continue
		said.append({"id": int(row.id), "day": int(row.day), "minute": int(row.minute), "end_minute": int(row.end_minute),
			"place": str(row.place), "kind": "say", "speaker": str(row.speaker), "listener": str(row.listener), "text": text})
	return said


## A journal event told as a line of the story, or "" when it is bookkeeping.
static func moment_text(row: Dictionary, player := "Anon", outcome: RegEx = null) -> String:
	var text := str(row.text).strip_edges()
	match str(row.kind):
		"arrival", "rumour": return text
		"action_outcome":
			var found := (outcome if outcome != null else RegEx.create_from_string(OUTCOME)).search(text)
			if found == null or not MOMENTS.has(found.get_string(1)): return ""
			return str(MOMENTS[found.get_string(1)]).format({"a": name_of(str(row.speaker), player), "p": player})
	return ""


## Entries gathered into scenes, oldest first: {index, day, start, end, place, entries, cast}.
static func scenes_of(entries: Array) -> Array:
	var scenes: Array = []
	var scene: Dictionary = {}
	for entry: Dictionary in entries:
		var place := str(entry.place)
		if scene.is_empty() or int(entry.day) != int(scene.day) or int(entry.minute) - int(scene.end) > SCENE_GAP \
				or (place != "" and str(scene.place) != "" and place != str(scene.place)):
			scene = {"index": scenes.size(), "day": int(entry.day), "start": int(entry.minute), "end": int(entry.end_minute),
				"place": place, "entries": [], "cast": []}
			scenes.append(scene)
		scene.entries.append(entry)
		scene.end = maxi(int(scene.end), int(entry.end_minute))
		if str(scene.place) == "": scene.place = place
		for who: String in [str(entry.speaker), str(entry.listener)]:
			if who != PLAYER and who not in NOBODY and who not in scene.cast: scene.cast.append(who)
	return scenes


## The scenes `chosen` (pony ids; empty = everypony) take part in on `day` (-1 = every day), newest
## first, each with only its entries about them: what they said, what was said to them and the
## player's words to nopony in particular. `moments` false leaves the moments out. `query` (the
## page's search box) keeps only the lines that hold every word of it, in the words said or in
## the name of who said them or was spoken to; letter case does not count.
static func filtered(scenes: Array, chosen: Array, day: int, moments: bool, query := "") -> Array:
	var shown: Array = []
	var words := query.to_lower().split(" ", false)
	var names := {}
	for i in range(scenes.size() - 1, -1, -1):
		var scene: Dictionary = scenes[i]
		if day >= 0 and int(scene.day) != day: continue
		var kept: Array = []
		for entry: Dictionary in scene.entries:
			if entry.kind == "moment" and not moments: continue
			if not words.is_empty():
				var text := str(entry.text).to_lower()
				for who: String in [str(entry.speaker), str(entry.listener)]:
					if not names.has(who): names[who] = name_of(who).to_lower()
					text += " " + str(names[who])
				var found := true
				for word: String in words:
					if not text.contains(word): found = false; break
				if not found: continue
			if chosen.is_empty() or str(entry.speaker) in chosen or str(entry.listener) in chosen \
					or (str(entry.speaker) == PLAYER and str(entry.listener) in NOBODY) or (entry.kind == "moment" and str(entry.speaker) == ""):
				kept.append(entry)
		if kept.is_empty() or (not chosen.is_empty() and not kept.any(func(e: Dictionary) -> bool: return str(e.speaker) in chosen or str(e.listener) in chosen)):
			continue
		var copy := scene.duplicate()
		copy.entries = kept
		shown.append(copy)
	return shown


static func player_name() -> String:
	var name := str(AI_CONFIG.load_config().get_value("player_name", "Anon")).strip_edges()
	return name if name != "" else "Anon"


static func name_of(id: String, player := "Anon") -> String:
	if id == PLAYER: return player
	if id in NOBODY: return ""
	return str(PONY_DATA.appearance(id).name)


static func clock(minute: int) -> String:
	return "%02d:%02d" % [int(posmod(minute, 1440) / 60.0), posmod(minute, 60)]


static func place_name(place: String) -> String:
	if place == "" or ":" in place: return ""
	return place.replace("_", " ").capitalize()


## "Day 3 · 16:25–16:52 · Ponyville"
static func scene_line(scene: Dictionary) -> String:
	var bits: Array[String] = ["Day %d" % (int(scene.day) + 1)]
	bits.append(clock(int(scene.start)) + ("" if int(scene.end) - int(scene.start) < 2 else "–" + clock(int(scene.end))))
	if place_name(str(scene.place)) != "": bits.append(place_name(str(scene.place)))
	return " · ".join(bits)
