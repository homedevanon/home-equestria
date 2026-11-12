extends RefCounted
## Town talk grounded in the real town (thread 43671981 report 2026-11-03: the director notes'
## ELSEWHERE line was invented with no world state. Applejack "set up a cider stand in the market"
## while she was at home and other ponies repeated it as fact for hours; Spike sorted quills four
## times in 25 minutes; "small orgy of cuteness" was copied from the pony's own reply).
## - town_now(): a short TOWN NOW list for the notes turn: a few real off-screen ponies and what their
##   day plan has them doing, plus the newest finished day steps; ELSEWHERE picks from it. Ponies a
##   recent rumour already named are left out.
## - keep(): a new rumour is skipped when it repeats a recent one (similar words among the last
##   RECENT_RUMOURS, or the same pony within SAME_PONY_MINUTES) or reuses a PHRASE_WORDS-word phrase
##   from what the speaker heard or said lately.
## - Stored with PREFIX: hearsay, never fact. where_now(): ponies Anon names who are not here, with
##   where they really are, so a real location wins over an old rumour.
## Every token is paid in full (dev 2026-10-14): one short line, only on notes turns.
const ESSENCE := preload("res://world/life/essence.gd")
const STORE := preload("res://world/ai/memory/story_store.gd")
const PREFIX := "Talk around town (unconfirmed): "
const LIST_PONIES := 4
const LIST_EVENTS := 2
const RECENT_RUMOURS := 6
const SAME_PONY_MINUTES := 120
const PHRASE_WORDS := 4
## Off-screen ponies sampled for the list; each is one day-card lookup.
const SAMPLE := 24
## Capitalized words that never name a pony (sentence starts, places, days).
const NOT_NAMES := ["the", "a", "an", "some", "someone", "somepony", "everypony", "nopony", "anon", "apparently", "word", "rumour",
	"rumor", "heard", "talk", "town", "ponyville", "market", "square", "today", "tonight", "this", "that", "there", "over", "down",
	"up", "at", "in", "on", "by", "from", "and", "but", "two", "three", "few", "several", "all", "princess", "miss", "mr", "mrs",
	# where_now(): first names that are everyday words ("I feel lucky" is not Lucky Clover).
	"lucky", "golden", "cherry", "lemon", "rose", "star", "sunny", "night", "cloud", "green", "silver", "royal", "grand", "sugar",
	"sweet", "blue", "daisy", "lily", "good", "great", "little", "first", "dark", "light", "rain", "snow", "berry", "honey", "apple"]
## Resident reasons that say nothing worth gossip.
const DULL := ["Settling into the day", "Returning to the afternoon"]

## What resident `id` is really doing now, in a few words, or "".
static func doing(tree: SceneTree, id: String) -> String:
	if tree == null: return ""
	var population: Node = tree.get_first_node_in_group("pony_populations")
	if population == null: return ""
	var rest: Node = tree.get_first_node_in_group("night_rest")
	var resident := ESSENCE.record(population, id)
	if bool(resident.get("asleep", false)) or (rest != null and rest.has_method("is_asleep") and rest.is_asleep(id)): return "asleep at home"
	var runner: Node = tree.get_first_node_in_group("day_runner")
	var cards: Variant = runner.get("cards") if runner != null else null
	if cards is Dictionary and (cards as Dictionary).has(id):
		var card: Dictionary = cards[id]
		var steps: Array = card.get("steps", [])
		var index := int(card.get("index", 0))
		var running: bool = card.get("action") != null or not (card.get("essence", {}) as Dictionary).is_empty()
		if running and index < steps.size() and runner.has_method("_text"): return str(runner.call("_text", steps[index]))
	var live: Dictionary = population.get("live").get(id, {}) if population.get("live") is Dictionary else {}
	var actor: Variant = live.get("actor")
	if is_instance_valid(actor) and (actor as Node).has_meta("life_intent"): return str((actor as Node).get_meta("life_intent"))
	var reason := str(resident.get("last_reason", ""))
	if reason.is_empty() or reason in DULL: return ""
	return reason.trim_prefix("Today's plan: ")

## Every resident id the day plans know (pony_population config assignments).
static func residents(tree: SceneTree) -> Array:
	var population: Node = tree.get_first_node_in_group("pony_populations") if tree != null else null
	var config: Variant = population.get("config") if population != null else null
	var assignments: Variant = config.get("assignments") if config != null else null
	return (assignments as Dictionary).keys() if assignments is Dictionary else []

## The TOWN NOW line for a notes turn, or "" (no world, nothing known). `present`: ids around the
## speaker; `rumours`: recent rumour texts; `events`: recent finished day steps (journal "day" rows,
## newest last); `name_of`: id -> display name; `seed` varies the pick between turns.
static func town_now(tree: SceneTree, present: Array, rumours: Array, events: Array, name_of: Callable, seed: int) -> String:
	var said := " ".join(rumours.map(func(text): return str(text).to_lower()))
	var ids := residents(tree).filter(func(id): return str(id) not in present)
	ids.sort_custom(func(a, b): return hash(str(a) + str(seed)) < hash(str(b) + str(seed)))
	var picked: PackedStringArray = []
	for id in ids.slice(0, SAMPLE):
		if picked.size() >= LIST_PONIES: break
		var name := str(name_of.call(str(id)))
		if name.is_empty() or said.contains(name.to_lower().get_slice(" ", 0)): continue
		var now := doing(tree, str(id))
		if not now.is_empty(): picked.append("%s: %s" % [name, now.strip_edges().trim_suffix(".")])
	var lately: PackedStringArray = []
	for i in range(events.size() - 1, -1, -1):
		if lately.size() >= LIST_EVENTS: break
		var row: Dictionary = events[i]
		if str(row.get("speaker", "")) in present: continue
		var text := str(row.get("text", "")).strip_edges()
		if not text.is_empty() and not said.contains(text.to_lower().get_slice(" ", 0)): lately.append(text.trim_suffix("."))
	if picked.is_empty() and lately.is_empty(): return ""
	var line := "TOWN NOW (real, off-screen; ELSEWHERE picks one): " + "; ".join(picked)
	if not lately.is_empty(): line += (". " if not picked.is_empty() else "") + "Lately: " + "; ".join(lately)
	return line + "."

## Off-screen ponies named in Anon's words (at most two), with where they really are: a real
## location wins over an old rumour. "" when he names nopony absent.
static func where_now(tree: SceneTree, words: String, present: Array, name_of: Callable) -> String:
	var said := " " + RegEx.create_from_string("[^a-z0-9]+").sub(words.to_lower(), " ", true) + " "
	if said.strip_edges().is_empty(): return ""
	var found: PackedStringArray = []
	for id in residents(tree):
		if found.size() >= 2: break
		if str(id) in present: continue
		var name := str(name_of.call(str(id)))
		var first := name.to_lower().get_slice(" ", 0)
		if not said.contains(" " + name.to_lower() + " ") and (first.length() < 4 or first in NOT_NAMES or not said.contains(" " + first + " ")): continue
		var now := doing(tree, str(id))
		if not now.is_empty(): found.append("%s: %s" % [name, now.strip_edges().trim_suffix(".")])
	return "" if found.is_empty() else "- Where they really are now (beats any rumour you heard): " + "; ".join(found) + "."

## Capitalized words of a rumour that may name a pony (lower case).
static func subjects(text: String) -> Dictionary:
	var names := {}
	for word: String in RegEx.create_from_string("[^A-Za-z']+").sub(text, " ", true).split(" ", false):
		var bare := word.trim_suffix("'s").trim_suffix("'")
		if bare.length() < 3 or bare.left(1) != bare.left(1).to_upper() or bare.left(1) == bare.left(1).to_lower(): continue
		if bare.to_lower() in NOT_NAMES: continue
		names[bare.to_lower()] = true
	return names

## Lower-case word runs of PHRASE_WORDS words.
static func phrases(text: String) -> Dictionary:
	var words := RegEx.create_from_string("[^a-z0-9']+").sub(text.to_lower(), " ", true).split(" ", false)
	var runs := {}
	for i in range(0, words.size() - PHRASE_WORDS + 1):
		runs[" ".join(words.slice(i, i + PHRASE_WORDS))] = true
	return runs

## Why a new rumour is skipped, or "" to keep it. `recent`: the newest rumour rows ({text, day,
## minute}); `said`: texts the speaker heard or said lately; `now`: {day, minute}.
static func reject(text: String, recent: Array, said: Array, now: Dictionary) -> String:
	var body := text.strip_edges()
	if body.length() < 8 or body.to_lower().trim_suffix(".") in ["none", "nothing", "n/a", "-", "nothing new"]: return "empty"
	var who := subjects(body)
	var at := int(now.get("day", 0)) * 1440 + int(now.get("minute", 0))
	for row: Dictionary in recent:
		var old := str(row.get("text", "")).trim_prefix(PREFIX).trim_prefix("Talk around town: ")
		if STORE.similar(old, body): return "repeats a recent rumour"
		var then := int(row.get("day", 0)) * 1440 + int(row.get("minute", 0))
		if at - then <= SAME_PONY_MINUTES:
			for name: String in subjects(old):
				if who.has(name): return "same pony as a rumour %d minutes ago" % (at - then)
	var mine := phrases(body)
	if not mine.is_empty():
		for line in said:
			for run: String in phrases(str(line)):
				if mine.has(run): return "reuses \"%s\" from the conversation" % run
	return ""

## M-AI-15 notoriety (pony_impressions.gd): ponies talking together pass on what they heard about
## Anon's cruelty to the mares. Each who knows tells each who knows less; the listener remembers it
## as gossip (a world event: her own memory, no extra AI request). Returns how many learned of it.
static func spread_notoriety(context: Node, members: Array) -> int:
	if not is_instance_valid(context) or bool(context.get("_read_only")): return 0
	var impressions: Variant = context.get("impressions")
	if not impressions is Node or not is_instance_valid(impressions) or not (impressions as Node).has_method("retell"): return 0
	var deed := str(impressions.call("latest_deed"))
	if deed.is_empty(): return 0
	var told := 0
	for teller: Variant in members:
		for listener: Variant in members:
			if str(teller) == str(listener) or not bool(impressions.call("retell", str(teller), str(listener))): continue
			told += 1
			context.call("record", "gossip", "%s told you: %s." % [str(teller).replace("_", " ").capitalize(), deed],
				[str(listener)], [str(teller), "player"], "notoriety:%s:%s:%s" % [str(teller), str(listener), deed.md5_text().left(8)])
	return told
