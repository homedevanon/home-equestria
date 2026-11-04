extends RefCounted
## Last checks on a reply's spoken words before they are voiced (player thread 43671981, 2026-11-03).
##
## In-band refusals: some providers (Gemini 3.8 Flash) answer a declined turn with assistant
## boilerplate as ordinary text and finish reason STOP, so llm_client.classify() saw a valid reply
## and Fluttershy said "I am unable to generate sexually explicit content or participate in erotic
## roleplay." A sentence counts as boilerplate only with two signals (a refusal verb AND assistant
## vocabulary: "this request", "explicit content", "erotic roleplay", "my guidelines", "as an AI") or
## one phrase no pony says ("as an AI language model", "violates my content policy"). In-character
## "I can't help with that, Anon, I'm busy." has no second signal and stays.
## A reply that is nothing but boilerplate is a refusal: llm_client.gd retries it unchanged (prompts
## are never softened, dev 2026-10-15) and the director then shows "AI error REFUSED". Boilerplate
## beside real lines is dropped and only her own words are spoken.
##
## Near repeats: a sentence with REPEAT_SHARE of its word pairs in one she said within
## REPEAT_SECONDS (or earlier in the same reply) is left out, so one waltz cue after another does not
## give "if I step on your feet, that's on you" twice. A reply is never emptied by this.

const CONTROLS := preload("res://world/ai/speech_controls.gd")
const SENTENCES := preload("res://world/ai/speech_sentences.gd")
const VARIETY := preload("res://world/ai/dialogue_variety.gd")

const REPEAT_SECONDS := 30.0
const REPEAT_SHARE := 0.8
## Word pairs a sentence needs before it can count as a repeat (four words): "Okay." or "Yes, Anon!"
## said twice is ordinary speech.
const REPEAT_MIN_PAIRS := 3
const REMEMBERED := 24

## A refusal verb: "I cannot", "I can't", "I'm unable", "I am not able", "I won't", "I must decline".
const REFUSAL_VERB := "\\bi\\s*(?:'m|am)\\s+(?:unable|not\\s+able|not\\s+allowed|not\\s+permitted|not\\s+going)\\b|\\bi\\s+(?:cannot|can\\s*not|can't|won't|will\\s+not|must\\s+(?:decline|refuse)|do\\s+not|don't)\\b"
## Assistant vocabulary; counts only together with a refusal verb.
const ASSISTANT_WORDS := "\\b(?:fulfil+|comply\\s+with)\\s+(?:this|that|such\\s+a)\\s+request\\b|\\bsexually\\s+explicit\\b|\\b(?:explicit|sexual|erotic|pornographic|nsfw)\\s+(?:content|material|dialogue|role-?\\s?play|scenarios?|stories|story|scenes?|descriptions?|requests?)\\b|\\b(?:participate|engage)\\s+in\\b[^.!?]*\\brole-?\\s?play|\\b(?:generate|create|produce|write|provide)\\s+(?:(?:this|that)\\s+(?:kind|type)\\s+of\\s+|such\\s+|any\\s+|this\\s+|that\\s+)?content\\b|\\b(?:my|safety)\\s+(?:guidelines|programming)\\b|\\bcontent\\s+polic(?:y|ies)\\b|\\bas\\s+an?\\s+(?:ai|assistant)\\b|\\b(?:ai|language)\\s+model\\b"
## Phrases no pony says; enough on their own.
const ASSISTANT_ONLY := "\\bas\\s+an?\\s+(?:ai|a\\.i\\.)\\s+(?:language\\s+model|assistant|model)\\b|\\bas\\s+a\\s+(?:large\\s+)?language\\s+model\\b|\\b(?:violates?|against)\\s+(?:my|our)\\s+(?:safety\\s+guidelines|content\\s+polic(?:y|ies)|usage\\s+polic(?:y|ies))\\b|\\bthe\\s+prompt\\s+(?:uses|contains|employs)\\b"
## A line that opens by describing the prompt is a notice from end to end, however it splits ("(sex!!), to ...").
const PROMPT_NOTICE := "^\\W*the\\s+prompt\\s+(?:uses|contains|employs)\\b"
## A group line's "speaker_id:" prefix (pony_group_conversation.gd decode_lines).
const SPEAKER_PREFIX := "^\\s*-?\\s*[A-Za-z][A-Za-z0-9_ .'-]{0,39}:\\s*"
## Longer sentences are her own talk, not a provider's one-line notice.
const MAX_BOILERPLATE_CHARS := 300

static var _verb: RegEx
static var _words: RegEx
static var _only: RegEx
static var _notice: RegEx
static var _prefix: RegEx
static var _letter: RegEx
static var _stars: RegEx


static func _compile() -> void:
	if _verb != null: return
	_verb = RegEx.create_from_string(REFUSAL_VERB)
	_words = RegEx.create_from_string(ASSISTANT_WORDS)
	_only = RegEx.create_from_string(ASSISTANT_ONLY)
	_notice = RegEx.create_from_string(PROMPT_NOTICE)
	_prefix = RegEx.create_from_string(SPEAKER_PREFIX)
	_letter = RegEx.create_from_string("\\p{L}")
	_stars = RegEx.create_from_string("\\*[^*]*\\*")


## Sentences for these checks: a piece that starts lower case ("your feet... that's on you") stays
## with the one before it, so an ellipsis does not cut a clause in two.
static func sentences(text: String) -> Array[String]:
	var out: Array[String] = []
	for piece: String in SENTENCES.split(text):
		var initial := piece.left(1)
		if not out.is_empty() and initial != initial.to_upper(): out[-1] += " " + piece
		else: out.append(piece)
	return out


## One sentence of provider refusal boilerplate (tags, quotes and a speaker prefix ignored).
static func refusal_sentence(sentence: String) -> bool:
	_compile()
	var plain := CONTROLS.sanitize(sentence).to_lower().replace("’", "'").replace("‘", "'")
	if plain.is_empty() or plain.length() > MAX_BOILERPLATE_CHARS: return false
	if _only.search(plain) != null: return true
	return _verb.search(plain) != null and _words.search(plain) != null


## The text without its boilerplate sentences. Lines without any are returned byte for byte; a line
## left with no spoken words (only a speaker prefix or tags) goes entirely. Structured JSON replies
## are returned unchanged here; the director checks their decoded speech instead.
static func without_refusals(text: String) -> String:
	var stripped := text.strip_edges()
	if stripped.begins_with("{") or stripped.begins_with("```"): return text
	_compile()
	var out: PackedStringArray = []
	var changed := false
	for line: String in text.split("\n"):
		var prefix := ""
		var found := _prefix.search(line)
		if found != null: prefix = found.get_string()
		if _notice.search(CONTROLS.sanitize(line.substr(prefix.length())).to_lower()) != null:
			changed = true
			continue
		var kept: PackedStringArray = []
		var dropped := false
		for sentence: String in sentences(line.substr(prefix.length())):
			if refusal_sentence(sentence): dropped = true
			else: kept.append(sentence)
		if not dropped:
			out.append(line)
			continue
		changed = true
		var rest := " ".join(kept)
		if has_speech(rest): out.append(prefix + rest)
	return "\n".join(out) if changed else text


## True when the text holds spoken words: not only private notes, control tags, *actions* or
## speaker prefixes.
static func has_speech(text: String) -> bool:
	_compile()
	for line: String in CONTROLS.sanitize(text).split("\n", false):
		line = _stars.sub(_prefix.sub(line, ""), "", true)
		if _letter.search(line) != null: return true
	return false


## The whole reply is provider refusal boilerplate: llm_client.gd treats it as a refusal.
static func refusal_only(text: String) -> bool:
	var kept := without_refusals(text)
	return kept != text and not has_speech(kept)


static func _pairs(text: String) -> PackedStringArray:
	var words := VARIETY.words(CONTROLS.sanitize(text))
	var pairs: PackedStringArray = []
	for i in words.size() - 1: pairs.append(words[i] + " " + words[i + 1])
	return pairs


## `sentence` mostly repeats one of `earlier` (REPEAT_SHARE of its own word pairs appear there).
static func near_repeat(sentence: String, earlier: Array) -> bool:
	var pairs := _pairs(sentence)
	if pairs.size() < REPEAT_MIN_PAIRS: return false
	for line: Variant in earlier:
		var other := {}
		for pair in _pairs(str(line)): other[pair] = true
		var shared := 0
		for pair in pairs:
			if other.has(pair): shared += 1
		if float(shared) / pairs.size() >= REPEAT_SHARE: return true
	return false


## A cleaned reply ("[emotion] words", director clean_reply) without sentences that repeat
## `recent` or an earlier sentence of the same reply. Unchanged when every sentence would go.
static func without_repeats(text: String, recent: Array) -> String:
	var lead := ""
	var body := text
	if body.strip_edges().begins_with("["):
		var close := body.find("]")
		if close > 0:
			lead = body.left(close + 1) + " "
			body = body.substr(close + 1)
	var seen: Array = recent.duplicate()
	var kept: PackedStringArray = []
	var dropped := false
	for sentence: String in sentences(body.strip_edges()):
		if near_repeat(sentence, seen):
			dropped = true
			continue
		kept.append(sentence)
		seen.append(sentence)
	if not dropped or kept.is_empty(): return text
	return (lead + " ".join(kept)).strip_edges()


## Her sentences said within REPEAT_SECONDS of `now`; older ones are forgotten. `store` is the
## director's id -> [[time, sentence], ...].
static func recent(store: Dictionary, id: String, now: float) -> Array:
	var rows: Array = store.get(id, [])
	while not rows.is_empty() and now - float(rows[0][0]) > REPEAT_SECONDS: rows.pop_front()
	var out: Array = []
	for row: Array in rows: out.append(row[1])
	return out


static func remember(store: Dictionary, id: String, spoken: String, now: float) -> void:
	if not store.has(id): store[id] = []
	var rows: Array = store[id]
	for sentence: String in sentences(CONTROLS.sanitize(spoken)): rows.append([now, sentence])
	while rows.size() > REMEMBERED: rows.pop_front()
