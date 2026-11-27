extends RefCounted
## Who Anon is talking to (dev 2026-10-15: "the ai sometimes misunderstands who im talking to").
## Pure functions over plain data, so tools/test_addressee.gd replays the real failing save lines.
##
## Order, first match wins:
## 1. Names said as an address ("Hi Lyra", "Come on Derpy", "Dash, how...", "..., Tinky?"), including
##    first or last names, nicknames and one-letter speech-to-text slips ("Darpy"). A name used as a
##    subject or object ("Twilight saved me", "raising Dinky") is only a mention, never an address.
## 2. "you two", "everypony", "any of you": everyone present (the group path, starting with 3/4/5 below).
## 3. Follow-up without a name: the pony who just spoke with him, still close, keeps the floor
##    (Twilight said "There's a dictionary I need to buy", Anon said "So then come on, let's go!" while
##    looking at the Mayor, and the Mayor answered). A bare greeting ("Hello!") goes to his gaze instead.
## 4. The pony in his gaze cone.  5. The nearest pony who can hear him.
## No model call: the result is one short line in the group request, about 30 tokens.

## Her line finished this recently: an unnamed reply is still for her.
const FOLLOW_UP_SECONDS := 20.0
## Longer when she asked him something.
const FOLLOW_UP_QUESTION_SECONDS := 40.0
## A conversation partner stands near; farther away the gaze or nearest pony wins.
const FOLLOW_UP_RANGE := 8.0
## Score of one name occurrence.
const MENTION := 1
const WEAK_ADDRESS := 2
const ADDRESS := 3

## Words in front of a name that make it an address.
const ADDRESS_WORDS := ["hi", "hey", "hello", "howdy", "heya", "hiya", "yo", "bye", "goodbye", "morning", "night",
	"evening", "afternoon", "thanks", "okay", "ok", "oh", "so", "wait", "please", "sorry", "listen", "look", "dear",
	"well", "yes", "yeah", "no", "nope", "um", "uh", "hmm", "ah", "ugh", "aw", "aww", "goodnight", "cheers", "welcome"]
## A name opening a sentence and followed by one of these is an address ("Twilight come with me").
const ADDRESS_FOLLOWERS := ["come", "let's", "lets", "look", "wait", "stop", "follow", "please", "get", "go", "sit",
	"stand", "you", "you're", "your", "u", "what", "where", "how", "why", "who", "when", "if", "just", "want", "wanna",
	"i", "i'm", "we", "we're", "guess", "check", "hold", "help", "give", "take", "watch", "don't", "thank", "thanks",
	"hi", "hey", "hello", "listen", "be", "tell", "stay", "put", "bring", "try"]
## These open a question only with a person after them: "Dash can you...", not "Twilight can do magic".
const QUESTION_WORDS := ["can", "could", "would", "will", "do", "did", "are", "were", "have", "is", "should"]
## A name at the end of a sentence after one of these is its object, not an address ("raising Dinky?").
const OBJECT_WORDS := ["to", "from", "with", "for", "of", "about", "at", "by", "like", "than", "and", "or", "the",
	"a", "see", "saw", "met", "meet", "love", "loves", "help", "tell", "told", "ask", "asked", "raising", "is", "was",
	"call", "called", "find", "found", "visit", "know", "knew", "remember", "named", "name", "into", "on", "behind"]
## Greeting words that open a new exchange with whoever he looks at.
const GREETINGS := ["hi", "hello", "hey", "howdy", "heya", "hiya", "yo", "greetings"]
## Fan nicknames and speech-to-text spellings, by pony id. A profile's own "aliases" add to these.
const NICKNAMES := {
	"rainbow_dash": ["dashie", "rd", "dash", "rainbow"], "twilight_sparkle": ["twi", "twily", "twilie", "twiley", "twyla"],
	"applejack": ["aj", "apple jack"], "pinkie_pie": ["pinky", "pinks", "pinkie", "pinky pie"],
	"fluttershy": ["flutters", "flutter shy"], "celestia": ["sunbutt", "tia", "celly", "princess celestia"],
	"luna": ["lulu", "princess luna"], "big_mcintosh": ["big mac", "big mack", "mac"], "derpy_hooves": ["ditzy", "derp"],
	"octavia_melody": ["tavi", "octavia"], "vinyl_scratch": ["vinyl", "dj pon3", "dj pon-3"], "bon_bon": ["bonbon"],
	"scootaloo": ["scoots", "scoot"], "sweetie_belle": ["sweetie"], "apple_bloom": ["applebloom", "bloom"],
	"trixie": ["trix", "trixie"], "mayor_mare": ["mayor", "madam mayor", "miss mayor"], "dinky_doo": ["dinky"],
	"starlight_glimmer": ["starlight"], "nurse_redheart": ["nurse", "redheart"],
	"spike": ["spikey", "spikey wikey", "spikey-wikey", "spike the dragon", "dragon"]}
## Name parts too common as English words to stand alone for a pony.
const COMMON_PARTS := ["pie", "star", "sweet", "apple", "berry", "wings", "hearts", "heart", "lace", "rock",
	"blossom", "mare", "tail", "swirl", "gem", "links", "lane", "flower", "harvest", "valley", "shadow", "armor",
	"light", "dust", "fire", "trail", "sky", "skies", "rays", "spoon", "spanner", "mint", "punch", "finish", "favor",
	"quartz", "kicker", "fly", "hooves", "big", "king", "prince", "white", "wild", "red", "blue", "golden", "night",
	"moon", "dancer", "cloud", "clear", "comet", "diamond", "double", "lily", "silver", "royal", "ribbon", "orange",
	"perfect", "photo", "sea", "dr", "mrs", "ms", "mr", "melody", "scratch", "sparkle", "glimmer", "shimmer",
	"bloom", "belle", "doo", "bon", "flash", "lemon", "cherry", "lotus", "sugar", "sunny", "merry", "may", "misty",
	"daring", "do", "nurse", "pinny", "prim", "raven", "rose", "tree", "hugger", "twist", "surprise", "daisy",
	"caramel", "jackpot", "archer", "spices", "brass", "beauty", "fluff", "banana", "bobbin", "bumpkin", "inkwell",
	"rich", "filthy", "velvet", "dawn", "montage", "glider", "flare", "stellar", "raindrops", "shake", "shimmy",
	"medley", "sprinkle", "rainbow", "pinch", "ruby", "sunrise", "strawberry", "noteworthy", "party", "compass",
	"tart", "lightning", "marble", "meadow", "shy", "gala", "shining", "sunset", "vapor", "windy", "whistles",
	"cloudy", "the", "of", "and"]
const GROUP_ADDRESS := ["you two", "you three", "you both", "both of you", "all of you", "you all", "y'all", "yall",
	"you guys", "you girls", "everypony", "everyone", "everybody", "every pony", "anypony", "any of you", "ladies",
	"girls", "hi all", "hey all", "hello all"]


## The words a pony answers to: her name, its distinctive parts, profile aliases and fan nicknames.
static func names_for(id: String, profile: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var raw: Array = [str(profile.get("name", id)), id.replace("_", " ")]
	raw.append_array(profile.get("aliases", []))
	raw.append_array(NICKNAMES.get(id, []))
	for value: Variant in raw:
		var phrase := " ".join(_words(str(value)))
		if phrase != "" and phrase not in out: out.append(phrase)
	for value: Variant in [str(profile.get("name", id)), id.replace("_", " ")]:
		for part: String in _words(str(value)):
			if part.length() >= 3 and part not in COMMON_PARTS and part not in out: out.append(part)
	return out


## Lowercase words of a line, apostrophes kept ("derpy's" is not "derpy").
static func _words(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for m: RegExMatch in _word_regex().search_all(text.to_lower().replace("’", "'")): out.append(m.get_string())
	return out


static var _regex: RegEx
static func _word_regex() -> RegEx:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile("[a-z0-9][a-z0-9'\\-]*")
	return _regex


static func group_address(text: String) -> bool:
	var line := " " + " ".join(_words(text)) + " "
	for phrase: String in GROUP_ADDRESS:
		if (" " + phrase + " ") in line: return true
	return false


static func greeting_led(text: String) -> bool:
	var words := _words(text)
	return not words.is_empty() and (words[0] in GREETINGS or (words.size() > 1 and words[0] == "good" and words[1] in ["morning", "afternoon", "evening"]))


## Best score per candidate id with the text position of its best occurrence:
## {id: {"score": int, "at": int}}. `candidates` holds {id, names}.
static func name_scores(text: String, candidates: Array) -> Dictionary:
	var lowered := text.to_lower().replace("’", "'")
	var matches: Array[RegExMatch] = _word_regex().search_all(lowered)
	var words: Array[String] = []
	for m in matches: words.append(m.get_string())
	var result := {}
	var vocative_end := -2
	# Exact names first; a one-letter slip ("Darpy") counts only for a word no name matched exactly,
	# only in an address position and below an exact address ("Pinky" is Pinkie, not Dinky or Linky).
	for fuzzy: bool in [false, true]:
		for i in words.size():
			if fuzzy and words[i] in _exact_words(result): continue
			for candidate: Dictionary in candidates:
				var id := str(candidate.get("id", ""))
				for name_text: String in candidate.get("names", []):
					var parts := name_text.split(" ")
					var length := 0
					if not fuzzy: length = _match_length(words, i, parts)
					elif parts.size() == 1 and parts[0].length() >= 5 and words[i].length() >= 5 and _near(words[i], parts[0]): length = 1
					if length == 0: continue
					var score := _occurrence_score(lowered, matches, words, i, i + length - 1, vocative_end)
					if fuzzy:
						if score < ADDRESS: continue
						score = WEAK_ADDRESS
					elif score >= ADDRESS: vocative_end = i + length - 1
					var old: Dictionary = result.get(id, {"score": 0, "at": 1 << 30})
					if score > int(old.score): result[id] = {"score": score, "at": matches[i].get_start(), "word": words[i]}
					break
	return result


static func _exact_words(result: Dictionary) -> Array:
	return result.values().map(func(row: Dictionary) -> String: return str(row.get("word", "")))


static func _match_length(words: Array[String], at: int, parts: PackedStringArray) -> int:
	if at + parts.size() > words.size(): return 0
	for k in parts.size():
		if words[at + k] != parts[k]: return 0
	return parts.size()


## One substitution, insertion or deletion apart: "darpy"/"derpy", "tinky"/"dinky".
static func _near(a: String, b: String) -> bool:
	if absi(a.length() - b.length()) > 1 or a == b: return a == b
	var i := 0
	var j := 0
	var edits := 0
	while i < a.length() and j < b.length():
		if a[i] == b[j]: i += 1; j += 1; continue
		edits += 1
		if edits > 1: return false
		if a.length() > b.length(): i += 1
		elif a.length() < b.length(): j += 1
		else: i += 1; j += 1
	return edits + (a.length() - i) + (b.length() - j) <= 1


static func _occurrence_score(text: String, matches: Array[RegExMatch], words: Array[String], first: int, last: int, vocative_end: int) -> int:
	var before := text.substr(matches[first - 1].get_end(), matches[first].get_start() - matches[first - 1].get_end()) if first > 0 else ""
	var after_end := matches[last + 1].get_start() if last + 1 < matches.size() else text.length()
	var after := text.substr(matches[last].get_end(), after_end - matches[last].get_end())
	var at_start := first == 0 or _ends_sentence(before)
	var at_end := last + 1 >= words.size() or _ends_sentence(after)
	var previous := "" if at_start else words[first - 1]
	var following := words[last + 1] if last + 1 < words.size() and not at_end else ""
	# A stuttered name ("Mayor Mayor, please...") scores as one.
	if previous == words[first]: return _occurrence_score(text, matches, words, first - 1, last, vocative_end)
	if previous in ADDRESS_WORDS: return ADDRESS
	if previous == "on" and first >= 2 and words[first - 2] == "come": return ADDRESS
	if (previous == "and" or "," in before) and vocative_end == first - (2 if previous == "and" else 1): return ADDRESS
	var asks := following in QUESTION_WORDS and last + 2 < words.size() and words[last + 2] in ["you", "we", "i", "u", "y'all"]
	if at_start and ("," in after or "!" in after or "?" in after or at_end or following in ADDRESS_FOLLOWERS or asks): return ADDRESS
	if at_end and "," in before: return ADDRESS
	if (at_end or "," in after) and previous not in OBJECT_WORDS: return WEAK_ADDRESS
	return MENTION


static func _ends_sentence(gap: String) -> bool:
	return "." in gap or "!" in gap or "?" in gap


## `candidates`: ponies who can hear Anon, nearest first, each {id, names, distance}.
## `gazed`: the pony in his gaze cone or "". `partner`: {id, at, question} of the last pony in an
## exchange with him (empty when none). Returns {id, reason, addressed: Array[String], everyone: bool}.
## reason: named, everyone, follow_up, gaze, nearest, or "" when nobody can hear.
static func resolve(text: String, candidates: Array, gazed: String, partner: Dictionary, now: float) -> Dictionary:
	var result := {"id": "", "reason": "", "addressed": [] as Array[String], "everyone": false}
	if candidates.is_empty(): return result
	var order: Array[String] = []
	for candidate: Dictionary in candidates: order.append(str(candidate.id))
	var fresh := _fresh_partner(candidates, partner, now)
	var rank := func(id: String) -> int: return 0 if id == gazed else (1 if id == fresh else 2 + order.find(id))
	var scores := name_scores(text, candidates)
	var best := 0
	for id: String in scores: best = maxi(best, int(scores[id].score))
	result.everyone = group_address(text)
	if best >= WEAK_ADDRESS:
		var addressed: Array[String] = []
		for id: String in order:
			if scores.has(id) and int(scores[id].score) == best: addressed.append(id)
		addressed.sort_custom(func(a: String, b: String) -> bool:
			var at_a := int(scores[a].at); var at_b := int(scores[b].at)
			return at_a < at_b if at_a != at_b else rank.call(a) < rank.call(b))
		result.addressed = addressed
		result.id = addressed[0]
		result.reason = "everyone" if result.everyone else "named"
		return result
	if gazed != "" and gazed not in order: gazed = ""
	if result.everyone:
		result.addressed = order.duplicate()
		result.id = gazed if gazed != "" else (fresh if fresh != "" else order[0])
		result.reason = "everyone"
	elif fresh != "" and not (greeting_led(text) and gazed != "" and gazed != fresh):
		result.id = fresh; result.reason = "follow_up"
	elif gazed != "":
		result.id = gazed; result.reason = "gaze"
	else:
		result.id = order[0]; result.reason = "nearest"
	if not result.everyone: result.addressed = [result.id] as Array[String]
	return result


static func _fresh_partner(candidates: Array, partner: Dictionary, now: float) -> String:
	var id := str(partner.get("id", ""))
	if id == "": return ""
	var window := FOLLOW_UP_QUESTION_SECONDS if bool(partner.get("question", false)) else FOLLOW_UP_SECONDS
	if now - float(partner.get("at", -1e9)) > window: return ""
	for candidate: Dictionary in candidates:
		if str(candidate.id) == id: return id if float(candidate.get("distance", 0.0)) <= FOLLOW_UP_RANGE else ""
	return ""


## One short line for the group request: whom Anon is speaking to and why. "" when nothing is known.
static func hint(address: Dictionary, partner: Dictionary) -> String:
	var id := str(address.get("id", ""))
	match str(address.get("reason", "")):
		"named":
			var addressed: Array = address.get("addressed", [])
			if addressed.size() > 1: return "Anon is speaking to %s (he named them)." % ", ".join(PackedStringArray(addressed))
			return "Anon is speaking to %s (he named her); she answers first." % id
		"everyone": return "Anon is speaking to everyone here."
		"follow_up":
			var said := str(partner.get("text", "")).strip_edges()
			if said == "": return "Anon is carrying on his talk with %s, so she will answer first." % id
			return "Anon is replying to %s's last line to him (\"%s\"), so she goes first." % [id, said.left(100)]
		"gaze": return "Anon is looking at %s as he speaks." % id
	return ""
