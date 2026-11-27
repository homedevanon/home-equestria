extends RefCounted
## Conservative grammar for deliberate requests; ambiguous conversation stays dialogue.
## Entire utterances must match. Quoting, reported speech and conditional wording never consent.
## 2026-11-19 (THREAD_FIX_RELATIONSHIP, romance_rules.FACTS): a request may also be one whole
## sentence of a longer line ("Trixie, I really like you. Will you be my marefriend?"), her name may
## close it ("..., Trixie?"), and a few more everyday phrasings of asking her out count. Answers still
## have to be the whole utterance, and the rejections below still apply to the whole line.
const RULES := preload("res://world/relationships/romance_rules.gd")
## Relationship overhaul 2026-11-21: how often parse() was called (test_bond_old_readers.gd).
static var reads := 0

static func whitespace(raw: String) -> String:
	var spacing := RegEx.new()
	spacing.compile("[ \t]+")
	return spacing.sub(raw.strip_edges(), " ", true)

static func normalize(raw: String, name: String = "") -> String:
	var text: String = whitespace(raw).to_lower().replace("’", "'")
	if text.contains('"') or text.contains("“") or text.contains("”") or text.contains("‘") or text.contains("`") or text.contains("\n"): return ""
	var first := name.to_lower().get_slice(" ", 0)
	for prefix: String in [name.to_lower() + ", ", "hey " + name.to_lower() + ", "] + ([first + ", ", "hey " + first + ", "] if RULES.FACTS else []):
		if not name.is_empty() and text.begins_with(prefix): text = text.trim_prefix(prefix)
	text = _trim_end(text)
	if RULES.FACTS and not name.is_empty():
		# Her name closing the line: "would you be my marefriend, Twilight?" (full or first name).
		for suffix: String in [", " + name.to_lower(), ", " + name.to_lower().get_slice(" ", 0)]:
			if text.ends_with(suffix): text = _trim_end(text.trim_suffix(suffix))
	for word: String in ["if", "maybe", "perhaps", "hypothetically", "imagine", "suppose", "supposing", "quote", "quoted", "saying", "said", "asked", "wonder", "wondering", "might", "unless", "whether"]:
		if matches(text, "(^|[^a-z])" + word + "([^a-z]|$)"): return ""
	if text.contains("'") and (text.begins_with("'") or text.ends_with("'")): return ""
	return text

static func _trim_end(text: String) -> String:
	while text.ends_with(".") or text.ends_with("!") or text.ends_with("?"):
		text = text.left(text.length() - 1).strip_edges()
	return text

static func matches(text: String, pattern: String) -> bool:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK: return false
	return regex.search(text) != null

static func parse(raw: String, name: String = "", answer_allowed: bool = true) -> Dictionary:
	reads += 1
	var text: String = normalize(raw, name)
	if text.is_empty(): return {}
	if answer_allowed:
		if matches(text, "^(yes(,)?( please| absolutely| of course| i'd love to)?|absolutely|of course|sure(,)?( i'd love to)?|i accept|i'd love to|i would love to|let's do it|i do|that sounds (lovely|great|wonderful))$"):
			return {"type": "answer", "accept": true}
		if matches(text, "^(no(,)?( thanks| thank you)?|not now(,)?( thanks)?|i decline|i'm not ready|i am not ready|i don't want to|i do not want to)$"):
			return {"type": "answer", "accept": false}
	var whole := _request(text)
	if not whole.is_empty() or not RULES.FACTS: return whole
	# One sentence of a longer line may be the request; each is checked on its own, negation included.
	var parts := RegEx.create_from_string("[.!?]+\\s+").sub(whitespace(raw), "\n", true).split("\n", false)
	if parts.size() < 2: return {}
	for part: String in parts:
		var sentence := normalize(part, name)
		if sentence.is_empty(): continue
		var found := _request(sentence)
		if not found.is_empty(): return found
	return {}

static func _request(text: String) -> Dictionary:
	# Negation must not fall through into a request. Answers above deliberately allow no.
	if matches(text, "(^|[^a-z])(not|never|don't|do not|wouldn't|would not|can't|cannot|won't|will not)([^a-z]|$)"): return {}
	for prefix: String in ["please, ", "please ", "so, ", "so ", "um, ", "well, "]:
		text = text.trim_prefix(prefix)
	for suffix: String in [", please", " please", ", i'd really like that", ", i'd like that"]:
		text = text.trim_suffix(suffix)
	var dating := "^(will|would|could) you( like to)? be my (girlfriend|marefriend|coltfriend|boyfriend|romantic partner)$|^(can|could|shall) we (start dating|be (a couple|girlfriend and boyfriend|marefriend and coltfriend))$|^(would you like to|let's) (start dating|be a couple)$|^be my (girlfriend|marefriend|coltfriend|boyfriend)$"
	if RULES.FACTS:
		dating += "|^(will|would|could) you (go out|go steady) with me$|^(do you|would you) want to (be my (girlfriend|marefriend|coltfriend|boyfriend)|go out with me|start dating)$|^(will|would) you be mine$|^i want you to be my (girlfriend|marefriend|coltfriend|boyfriend)$|^(will|would) you date me$"
	var patterns := {
		"dating": dating,
		"engagement": "^(will|would) you marry me$",
		"marriage": "^(let's|shall we) get married$|^i'm ready for our wedding$",
		"move_in": "^(can|could) i move in with you$|^(let's|shall we) (move in|live) together$",
		"kiss": "^(may|can|could) i kiss you$" + ("|^(can|could) i have a kiss$|^kiss me$" if RULES.FACTS else ""),
		"hug": "^(may|can|could) i hug you$",
		"break_up": "^(we should|i want to|i need to) break up$",
	}
	for kind: String in patterns:
		if matches(text, patterns[kind]): return {"type": "offer", "kind": kind, "activity": "walk"}
	if matches(text, "^(would you like to|will you|do you want to) go on a date( with me)?$"):
		return {"type": "offer", "kind": "date", "activity": "walk"}
	if matches(text, "^(would you like to|do you want to|shall we|let's) (have a picnic|share a picnic|have a meal)( with me| together)?$|^would you like a picnic( with me)?$"):
		return {"type": "offer", "kind": "outing", "activity": "meal"}
	for activity: String in ["walk", "fishing", "orchard", "meal", "visit"]:
		if matches(text, "^(let's go on a|would you like a|can we have a) " + activity + " date$"):
			return {"type": "offer", "kind": "date", "activity": activity}
		if matches(text, "^(let's go " + activity + " together|would you like to go " + activity + " with me)$"):
			return {"type": "offer", "kind": "outing", "activity": activity}
	return {}
