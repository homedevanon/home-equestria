extends RefCounted
## Want and reward grammar for favours (P2b, docs/MECHANICS_ARCHITECTURE_2026_11_01.md 5.2). Pure
## rules: the model's words ("2 apples", "fetch Fluttershy", "go to the town hall", "help at the
## cider stand"; "10 bits", "a cupcake", "thanks") become one normalised string each, checked
## against what is really possible (her purse, what she really has, the places she knows). Every
## ask source uses the same forms, so asks.gd, the notebook and the prompt read one grammar:
##   wants   item:<id>:<n>  tag:<tag>:<n>  place:<location_id>  fetch:<pony_id>  job:<job_id>:<n>  event:<event_id>
##   rewards bits:<n>  item:<id>  thanks
## Context keys read (all optional): purse (int), ask_items (ids she can give; else givables),
## locations + place_labels (her places), ask_ponies ({id: name}), ask_from (the asker),
## job_names ({id: name}; else data/jobs.json).
const ITEM_CATALOG := preload("res://world/inventory/item_catalog.gd")
const PLACES := preload("res://world/navigation/place_directory.gd")
## The tag vocabulary only (every lookup goes through the ITEM_CATALOG forwarders).
const ITEM_TAGS := preload("res://world/inventory/item_tags.gd")
const JOBS_PATH := "res://world/mechanics/data/jobs.json"
const EVENTS_PATH := "res://world/mechanics/data/events.json"
const MAX_COUNT := 12
const JOB_UNITS := 5
const MAX_BITS := 999
const TEXT_CHARS := 120
const KINDS := ["item", "tag", "place", "fetch", "job", "event"]
const NUMBER_WORDS := {"a": 1, "an": 1, "one": 1, "some": 1, "two": 2, "a couple of": 2, "couple of": 2, "a pair of": 2,
	"three": 3, "a few": 3, "few": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
	"eleven": 11, "twelve": 12, "a dozen": 12, "dozen": 12, "several": 3}
const THANKS_WORDS := ["", "thanks", "thank you", "thank-you", "nothing", "a hug", "hug", "hugs", "my thanks", "gratitude",
	"my gratitude", "a kiss on the cheek", "a smile", "friendship", "none", "free", "for free", "a favour", "a favor"]
## Tag words that make a fine "kind of thing" want; generic plumbing tags are never asked for.
const NOT_WANTED_TAGS := ["edible", "giftable", "sellable", "collectible", "container", "regional", "letter", "wardrobe"]
## Plural nouns for tag wants ("3 sweet things" reads better as "3 sweets").
const TAG_PLURALS := {"sweet": "sweets", "book": "books", "apple": "apples", "drink": "drinks", "meal": "meals",
	"fruit": "pieces of fruit", "fish": "fish", "plant": "plants", "painting": "paintings", "photo": "photos", "gem": "gems",
	"tea": "teas", "cider": "ciders", "fabric": "fabric things", "home_good": "home goods", "wear": "things to wear"}
const PLACE_VERB := "^(?:please\\s+)?(?:go(?!\\s+(?:get|fetch)\\b)|come|walk|trot|head|meet(?:\\s+me)?|visit|stop by|drop by|swing by)(?:\\s+(?:over|down|up|out|by))?(?:\\s+(?:to|at|by))?\\s+(.+)$"
const FETCH_VERB := "^(?:please\\s+)?(?:fetch|bring|get|find|call|go get|go fetch)(?:\\s+(?:me|us|over))?\\s+(.+)$"
const HELP_VERB := "^(?:please\\s+)?(?:help|work|lend a hoof|lend a hand|pitch in)(?:\\s+(?:out|me|us))?(?:\\s+(?:at|with|on|in))?\\s+(.+)$"
static var _jobs: Dictionary = {}
static var _events: Dictionary = {}

## {ok, want, reward, error}. Accepts the model's text or an already normalised string.
static func parse(want_text: String, reward_text: String, context: Dictionary) -> Dictionary:
	var want := parse_want(want_text, context)
	if not bool(want.ok): return {"ok": false, "want": "", "reward": "", "error": str(want.error)}
	var reward := parse_reward(reward_text, context)
	if not bool(reward.ok): return {"ok": false, "want": "", "reward": "", "error": str(reward.error)}
	if str(want.value) == "fetch:" + str(context.get("ask_from", "")): return {"ok": false, "want": "", "reward": "", "error": "Anon cannot fetch you to yourself"}
	return {"ok": true, "want": str(want.value), "reward": str(reward.value), "error": ""}

## {ok, value, error} for one want.
static func parse_want(text: String, context: Dictionary) -> Dictionary:
	var raw := text.strip_edges()
	if raw.is_empty() or raw.length() > TEXT_CHARS: return _fail("Say what the favour is: items and a count, fetch PONY, go to PLACE or help at JOB")
	var kind := raw.get_slice(":", 0)
	if kind in KINDS and raw.contains(":"): return _normal_want(raw, context)
	var lower := raw.to_lower().trim_suffix(".").trim_suffix("!").trim_suffix("?").strip_edges()
	lower = lower.trim_prefix("please ").trim_prefix("could you ").trim_prefix("can you ").strip_edges()
	# Go to a place: "go to the town hall", "meet me at Sugarcube Corner".
	var found := RegEx.create_from_string(PLACE_VERB).search(lower)
	if found != null:
		var place := PLACES.match_name(found.get_string(1), context.get("locations", []), context.get("place_labels", {}))
		if not place.is_empty(): return _ok("place:" + place)
	# Fetch a pony: "fetch Fluttershy"; "bring me 2 apples" carries on as items.
	found = RegEx.create_from_string(FETCH_VERB).search(lower)
	if found != null:
		var pony := match_pony(found.get_string(1), context.get("ask_ponies", {}))
		if not pony.is_empty(): return _ok("fetch:" + pony)
		lower = found.get_string(1)
	# Help at a job: "help at the cider stand", "help with apple bucking (3 baskets)".
	found = RegEx.create_from_string(HELP_VERB).search(lower)
	if found != null:
		var job := match_job(found.get_string(1), _job_names(context))
		if not job.is_empty():
			var units := _leading_count(found.get_string(1))
			var digits := RegEx.create_from_string("(\\d+)").search(found.get_string(1))
			return _ok("job:%s:%d" % [job, clampi(int(digits.get_string(1)) if digits != null else JOB_UNITS, 1, MAX_COUNT) if units.count < 0 else clampi(units.count, 1, MAX_COUNT)])
	return _item_want(lower)

## {ok, value, error} for one reward.
static func parse_reward(text: String, context: Dictionary) -> Dictionary:
	var lower := text.strip_edges().to_lower().trim_suffix(".").trim_suffix("!").strip_edges()
	if lower.length() > TEXT_CHARS: return _fail("Name the reward: bits you hold, an item you have, or thanks")
	if lower in THANKS_WORDS or lower.begins_with("thank"): return _ok("thanks")
	var purse: int = int(context.get("purse", 0)) if (context.get("purse") is int or context.get("purse") is float) else 0
	var bits := RegEx.create_from_string("^(?:bits:)?(\\d+)(?:\\s*(?:bits?|coins?))?$").search(lower)
	if bits == null: bits = RegEx.create_from_string("(\\d+)\\s*(?:bits?|coins?)\\b").search(lower)
	var spoken := _leading_count(lower)
	# "ten bits", "a few bits": number words count too.
	if bits == null and int(spoken.count) >= 1 and RegEx.create_from_string("^(?:bits?|coins?)$").search(str(spoken.rest)) != null:
		bits = RegEx.create_from_string("(\\d+)").search(str(spoken.count))
	if bits != null:
		var n := int(bits.get_string(1))
		if n < 1: return _ok("thanks")
		if n > MAX_BITS: return _fail("Offer at most %d bits" % MAX_BITS)
		if n > purse: return _fail("You only have %d bits to offer" % purse)
		return _ok("bits:%d" % n)
	var mine: Array = context.get("ask_items", context.get("givables", []))
	var item_text := lower.trim_prefix("item:")
	var count := _leading_count(item_text)
	var own := ITEM_CATALOG.match_name(str(count.rest), mine)
	if own.is_empty() and lower.begins_with("item:"): own = ITEM_CATALOG.match_name(text.strip_edges().substr(5), mine)
	if not own.is_empty(): return _ok("item:" + own)
	# She names something she does not have: refuse rather than promise it.
	if lower.begins_with("item:") or not ITEM_CATALOG.match_name(str(count.rest), ITEM_CATALOG.with_tag("giftable")).is_empty():
		return _fail("You do not have that to give as a reward")
	return _ok("thanks")

## Checks a normalised want (from data rows, events, or a second validation).
static func _normal_want(raw: String, context: Dictionary) -> Dictionary:
	var kind := raw.get_slice(":", 0)
	var rest := raw.substr(kind.length() + 1)
	match kind:
		"item", "tag", "job":
			var at := rest.rfind(":")
			if at <= 0 or not rest.substr(at + 1).is_valid_int(): return _fail("Name a count, e.g. %s:2" % raw)
			var id := rest.left(at)
			var n := int(rest.substr(at + 1))
			if n < 1 or n > MAX_COUNT: return _fail("A favour asks for 1 to %d" % MAX_COUNT)
			if kind == "item" and not (ITEM_CATALOG.has(id) and ITEM_CATALOG.has_tag(id, "giftable")): return _fail("Unknown thing to ask for")
			if kind == "tag" and (not id in _tag_vocabulary() or id in NOT_WANTED_TAGS): return _fail("Unknown kind of thing to ask for")
			if kind == "job" and not _id_ok(id): return _fail("Unknown work")
			var jobs := _job_names(context)
			if kind == "job" and not jobs.is_empty() and not jobs.has(id): return _fail("Unknown work")
			return _ok("%s:%s:%d" % [kind, ITEM_CATALOG.canonical(id) if kind == "item" else id, n])
		"place":
			var places: Array = context.get("locations", [])
			if rest.is_empty() or rest.length() > 96: return _fail("Unknown place")
			if context.has("locations") and not rest in places: return _fail("Unknown place")
			return _ok(raw)
		"fetch":
			var ponies: Dictionary = context.get("ask_ponies", {})
			if not _id_ok(rest) or (context.has("ask_ponies") and not ponies.has(rest)): return _fail("Unknown pony to fetch")
			return _ok(raw)
		"event":
			# Invitations are made by the game ([invite]), never asked for as a favour.
			if not bool(context.get("allow_event", false)) or not _id_ok(rest): return _fail("Invite Anon with [invite], not as a favour")
			return _ok(raw)
	return _fail("Unknown favour")

## Structural check of a normalised want or reward (asks.create from data, saves): "" or why not.
static func check_normal(want: String, reward: String) -> String:
	var checked := _normal_want(want, {"allow_event": true})
	if not bool(checked.ok): return str(checked.error)
	if reward == "thanks": return ""
	if reward.begins_with("bits:") and reward.substr(5).is_valid_int() and int(reward.substr(5)) >= 1 and int(reward.substr(5)) <= MAX_BITS: return ""
	if reward.begins_with("item:") and ITEM_CATALOG.has(reward.substr(5)): return ""
	return "Unknown reward"

## "2 apples", "a tea set", "3 sweets": an item or a kind of thing, with a count.
static func _item_want(lower: String) -> Dictionary:
	var count := _leading_count(lower)
	var noun := str(count.rest).trim_suffix(" please").strip_edges()
	for cut: String in [" for ", " from ", " because ", " so "]:
		if noun.contains(cut): noun = noun.get_slice(cut, 0).strip_edges()
	if noun.is_empty(): return _fail("Say what the favour is: items and a count, fetch PONY, go to PLACE or help at JOB")
	var n: int = clampi(int(count.count) if int(count.count) > 0 else 1, 1, MAX_COUNT)
	var giftable := ITEM_CATALOG.with_tag("giftable")
	var singular := _singular(noun)
	# An item named exactly ("apples" -> Apple) beats a kind of thing; a tag word beats a loose match.
	for word: String in [noun, singular]:
		# The id itself ("apple"), then the catalogue name ("tea set").
		for prefix: String in ["", "food:", "goods:"]:
			if prefix + word.replace(" ", "-") in giftable: return _ok("item:%s:%d" % [prefix + word.replace(" ", "-"), n])
		for id: String in giftable:
			if str(ITEM_CATALOG.definition(id).get("name", "")).to_lower() == word: return _ok("item:%s:%d" % [id, n])
	var vocabulary := _tag_vocabulary()
	for word: String in [noun.replace(" ", "_"), singular.replace(" ", "_")] + _words(noun):
		var tag := _singular(word).replace(" ", "_").replace("-", "_")
		if tag in vocabulary and not tag in NOT_WANTED_TAGS: return _ok("tag:%s:%d" % [tag, n])
		for pair: String in TAG_PLURALS:
			if str(TAG_PLURALS[pair]) == word and not pair in NOT_WANTED_TAGS: return _ok("tag:%s:%d" % [pair, n])
	var id := ITEM_CATALOG.match_name(noun, giftable)
	if not id.is_empty(): return _ok("item:%s:%d" % [id, n])
	return _fail("Ask for something real: items and a count (2 apples), fetch PONY, go to PLACE or help at JOB")

## {count (-1 when none), rest}: "2 apples", "a dozen apples", "three teas".
static func _leading_count(text: String) -> Dictionary:
	var lower := text.strip_edges().to_lower()
	var digits := RegEx.create_from_string("^(\\d+)\\s*(?:x\\s+)?(.*)$").search(lower)
	if digits != null: return {"count": int(digits.get_string(1)), "rest": digits.get_string(2).strip_edges()}
	var best := ""
	for word: String in NUMBER_WORDS:
		if (lower.begins_with(word + " ")) and word.length() > best.length(): best = word
	if not best.is_empty(): return {"count": int(NUMBER_WORDS[best]), "rest": lower.substr(best.length()).strip_edges().trim_prefix("of ").strip_edges()}
	return {"count": -1, "rest": lower}

static func _singular(word: String) -> String:
	if word.ends_with("ies") and word.length() > 4: return word.left(-3) + "y"
	if word.ends_with("ches") or word.ends_with("shes") or word.ends_with("xes"): return word.left(-2)
	if word.ends_with("s") and not word.ends_with("ss") and word.length() > 3: return word.left(-1)
	return word

static func _words(text: String) -> Array[String]:
	var out: Array[String] = []
	for word: String in text.replace("-", " ").split(" ", false):
		if word.length() >= 3 and not word in ["the", "and", "some", "few", "things", "thing", "stuff", "kind", "kinds"]: out.append(word)
	return out

static func _tag_vocabulary() -> Array:
	return ITEM_TAGS.VOCABULARY

## "" or the pony id `text` names: an id, a display name, or her first name.
static func match_pony(text: String, ponies: Dictionary) -> String:
	var wanted := text.strip_edges().to_lower().trim_prefix("miss ").trim_prefix("the ").strip_edges()
	for cut: String in [" to ", " for ", " here", " over", " please", " back"]:
		if wanted.contains(cut): wanted = wanted.get_slice(cut, 0).strip_edges()
	if wanted.is_empty(): return ""
	var key := wanted.replace(" ", "_").replace("-", "_")
	if ponies.has(key): return key
	for id: Variant in ponies:
		var name := str(ponies[id]).to_lower()
		if name == wanted or name.replace(" ", "") == wanted.replace(" ", ""): return str(id)
	for id: Variant in ponies:
		var name := str(ponies[id]).to_lower()
		if wanted.length() >= 4 and (name.begins_with(wanted + " ") or str(id).begins_with(key + "_")): return str(id)
	return ""

## "" or the job id `text` names (id or name, part of a name).
static func match_job(text: String, names: Dictionary) -> String:
	var wanted := text.strip_edges().to_lower().trim_prefix("the ").strip_edges()
	wanted = RegEx.create_from_string("\\s*\\(.*$|\\s+\\d+.*$").sub(wanted, "").strip_edges()
	if wanted.is_empty(): return ""
	var key := wanted.replace(" ", "_")
	if names.has(key): return key
	for id: Variant in names:
		var name := str(names[id]).to_lower()
		if name == wanted or (wanted.length() >= 4 and (name.contains(wanted) or wanted.contains(name))): return str(id)
	return ""

## Job ids and names: context job_names, else world/mechanics/data/jobs.json (once).
static func _job_names(context: Dictionary) -> Dictionary:
	var given: Variant = context.get("job_names")
	if given is Dictionary: return given
	if _jobs.is_empty():
		_jobs = _rows(JOBS_PATH, "jobs")
	return _jobs.get("names", {})

static func _rows(path: String, key: String) -> Dictionary:
	var names := {}
	var units := {}
	var places := {}
	if FileAccess.file_exists(path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		var list: Variant = (parsed as Dictionary).get(key, []) if parsed is Dictionary else []
		if list is Array:
			for row: Variant in list:
				if not row is Dictionary or not (row as Dictionary).get("id") is String: continue
				names[str(row.id)] = str((row as Dictionary).get("name", str(row.id).replace("_", " ")))
				units[str(row.id)] = str((row as Dictionary).get("unit", ""))
				places[str(row.id)] = str((row as Dictionary).get("place_name", ""))
	return {"names": names, "units": units, "places": places, "loaded": true}

static func _event_rows() -> Dictionary:
	if _events.is_empty(): _events = _rows(EVENTS_PATH, "events")
	return _events

# --- Plain words (notebook and prompt) --------------------------------------------------------

## "2 apples for 10 bits", "fetch Fluttershy", "help at the cider stand (5 mugs) for thanks".
static func describe(want: String, reward: String, labels := {}) -> String:
	var text := want_words(want, labels)
	return text if reward == "thanks" else "%s for %s" % [text, reward_words(reward)]

static func want_words(want: String, labels := {}) -> String:
	var kind := want.get_slice(":", 0)
	var rest := want.substr(kind.length() + 1)
	match kind:
		"item", "tag":
			var at := rest.rfind(":")
			var id := rest.left(at) if at > 0 else rest
			var n := int(rest.substr(at + 1)) if at > 0 else 1
			if kind == "tag":
				var plural := str(TAG_PLURALS.get(id, id.replace("_", " ") + " things"))
				return "a %s thing" % id.replace("_", " ") if n == 1 and not TAG_PLURALS.has(id) else ("%d %s" % [n, plural] if n > 1 else "one of your " + plural)
			var name := str(ITEM_CATALOG.definition(id).get("name", id)).to_lower()
			if n == 1: return ("an " if name.left(1) in ["a", "e", "i", "o", "u"] else "a ") + name
			return "%d %s" % [n, name if name.ends_with("s") else name + "s"]
		"place":
			var label := str(labels.get(rest, ""))
			if label.is_empty(): label = rest.get_slice(":", rest.get_slice_count(":") - 1).replace("_", " ")
			return "come to " + label
		"fetch":
			return "fetch " + str(labels.get(rest, rest.replace("_", " ").capitalize()))
		"job":
			var at := rest.rfind(":")
			var id := rest.left(at) if at > 0 else rest
			var n := int(rest.substr(at + 1)) if at > 0 else JOB_UNITS
			var jobs := _job_names({})
			if _jobs.is_empty(): _jobs = _rows(JOBS_PATH, "jobs")
			var unit := str((_jobs.get("units", {}) as Dictionary).get(id, ""))
			var name := str(jobs.get(id, id.replace("_", " ")))
			return "help at the %s" % name + (" (%d %s)" % [n, unit if n == 1 or unit.is_empty() else unit + "s"] if not unit.is_empty() else " (%d)" % n)
		"event":
			var events := _event_rows()
			var place := str((events.get("places", {}) as Dictionary).get(rest, ""))
			return str((events.get("names", {}) as Dictionary).get(rest, rest.replace("_", " ").capitalize())) + (" at " + place if not place.is_empty() else "")
	return want

static func reward_words(reward: String) -> String:
	if reward.begins_with("bits:"): return "%d bits" % int(reward.substr(5))
	if reward.begins_with("item:"):
		var name := str(ITEM_CATALOG.definition(reward.substr(5)).get("name", reward.substr(5))).to_lower()
		return ("an " if name.left(1) in ["a", "e", "i", "o", "u"] else "a ") + name
	return "thanks"

static func _id_ok(id: String) -> bool:
	if id.is_empty() or id.length() > 64: return false
	for c: String in id:
		if not c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-": return false
	return true

static func _ok(value: String) -> Dictionary:
	return {"ok": true, "value": value, "error": ""}

static func _fail(error: String) -> Dictionary:
	return {"ok": false, "value": "", "error": error}
