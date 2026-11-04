extends RefCounted
## The text of a letter (docs/LETTERS_PLAN_2026_10_29.md section 3.1): plain text with "\n"
## between lines, at most MAX_CHARS. A crossed-out sentence stays in the text between "~~"
## markers ("~~I hate rain.~~ I love rain."): the paper draws it struck through in ink and a
## reading pony sees it as crossed out. An unmatched "~~" is ignored. Shared by every letter
## builder: the paper, the scoring, the reader prompt and the fallback replies.
const MAX_CHARS := 6000
const STRIKE := "~~"
## Closings that may end a letter, followed by a name on the same line ("Love, Anon") or the
## next one ("Love," / "Anon").
const CLOSINGS := ["with love", "lots of love", "all my love", "love", "yours truly", "yours sincerely", "yours always",
	"yours", "sincerely", "best wishes", "best regards", "best", "your friend", "your best friend", "your pal",
	"from", "cheers", "warmly", "warm wishes", "take care", "hugs", "kind regards", "regards"]
const GREETINGS := ["my dearest", "my dear", "dearest", "dear"]
static var _re: Dictionary = {}

static func _regex(key: String, pattern: String) -> RegEx:
	if not _re.has(key):
		var compiled := RegEx.new(); compiled.compile(pattern)
		_re[key] = compiled
	return _re[key]

## Struck parts removed, spaces and blank lines tidied.
static func clean(text: String) -> String:
	var parts := _split(text)
	var kept := ""
	for part: Array in parts:
		if not bool(part[1]): kept += str(part[0])
	return tidy(kept)

## Struck parts become "[crossed out: ...]" so a reading pony sees what was crossed out.
static func for_reader(text: String) -> String:
	var out := ""
	for part: Array in _split(text):
		if bool(part[1]):
			var struck := str(part[0]).strip_edges()
			if not struck.is_empty(): out += "[crossed out: %s]" % struck
		else: out += str(part[0])
	return tidy(out)

## Each line's runs of spaces collapsed and trimmed, at most one blank line in a row, the whole
## thing trimmed and clipped to MAX_CHARS.
static func tidy(text: String) -> String:
	var lines := PackedStringArray()
	var blank := 0
	for raw: String in text.replace("\r", "").split("\n"):
		var line := _regex("spaces", "[ \\t]+").sub(raw, " ", true).strip_edges()
		if line.is_empty():
			blank += 1
			if blank > 1: continue
		else: blank = 0
		lines.append(line)
	return "\n".join(lines).strip_edges().left(MAX_CHARS)

## [[segment, struck]] in order. An odd last "~~" opens nothing: its text stays plain.
static func _split(text: String) -> Array:
	var result: Array = []
	var pieces := text.split(STRIKE)
	var closed := pieces.size() % 2 == 1
	for index in pieces.size():
		var struck := index % 2 == 1 and (closed or index < pieces.size() - 1)
		if index % 2 == 1 and not struck:
			# The unmatched marker: keep its text plain, after the previous plain piece.
			result.append([pieces[index], false]); continue
		result.append([pieces[index], struck])
	return result

## Crosses out the last sentence that is not crossed out yet (dictated or typed "scratch that");
## said again, it crosses out the one before. A sentence ends at . ! ? or a line break.
## Unchanged when there is nothing left to strike.
static func strike_last_sentence(text: String) -> String:
	# Plain (not struck) stretches of the text as [start, end], walked from the end.
	var spans: Array = []
	var at := 0
	for part: Array in _split(text):
		var length := str(part[0]).length()
		if not bool(part[1]): spans.append([at, at + length])
		at += length + STRIKE.length()
	for index in range(spans.size() - 1, -1, -1):
		var floor_at: int = spans[index][0]
		var end: int = mini(int(spans[index][1]), text.length())
		while end > floor_at and text[end - 1] in " \t\n": end -= 1
		if end <= floor_at or _regex("has_word", "[\\p{L}\\p{N}]").search(text.substr(floor_at, end - floor_at)) == null: continue
		# Skip the sentence's own closing punctuation, then walk back to the previous boundary.
		var cursor := end - 1
		while cursor > floor_at and text[cursor] in ".!?\"')": cursor -= 1
		var start := cursor
		while start > floor_at and not text[start - 1] in ".!?\n": start -= 1
		while start < end and text[start] in " \t": start += 1
		if start >= end: continue
		return text.substr(0, start) + STRIKE + text.substr(start, end - start) + STRIKE + text.substr(end)
	return text

## The name after "Dear" on the first line: "Dear Twilight," -> "Twilight", "Dear Princess Luna"
## -> "Princess Luna"; at most four words, up to the first comma or sentence mark. "" if none.
static func greeting_name(text: String) -> String:
	var first := ""
	for line: String in clean(text).split("\n", false):
		if not line.strip_edges().is_empty(): first = line.strip_edges(); break
	var lower := first.to_lower()
	for word: String in GREETINGS:
		if not lower.begins_with(word + " "): continue
		var rest := first.substr(word.length()).strip_edges()
		var stop := _regex("greet_stop", "[,!.:;?]").search(rest)
		if stop != null: rest = rest.substr(0, stop.get_start())
		var words_in := rest.strip_edges().split(" ", false)
		if words_in.is_empty(): return ""
		return " ".join(words_in.slice(0, mini(4, words_in.size()))).strip_edges()
	return ""

## How the letter ends: {"found", "closing", "name"} from its last two lines ("Love, Anon", or
## "Your friend," then "Anon", or "From Anon").
static func sign_off(text: String) -> Dictionary:
	var lines := PackedStringArray()
	for line: String in clean(text).split("\n", false):
		if not line.strip_edges().is_empty(): lines.append(line.strip_edges())
	var none := {"found": false, "closing": "", "name": ""}
	if lines.is_empty(): return none
	var last: String = lines[-1]
	var single := _regex("sign_one", "(?i)^(%s)\\s*[,.!-]+\\s*(.+)$" % "|".join(CLOSINGS)).search(last)
	if single != null and _name_like(single.get_string(2)):
		return {"found": true, "closing": _capital(single.get_string(1)), "name": _bare_name(single.get_string(2))}
	var from := _regex("sign_from", "(?i)^from\\s+(.+)$").search(last)
	if from != null and _name_like(from.get_string(1)):
		return {"found": true, "closing": "From", "name": _bare_name(from.get_string(1))}
	if lines.size() >= 2:
		var closing := _regex("sign_two", "(?i)^(%s)\\s*[,.!-]*$" % "|".join(CLOSINGS)).search(lines[-2])
		if closing != null and _name_like(last):
			return {"found": true, "closing": _capital(closing.get_string(1)), "name": _bare_name(last)}
	return none

static func _name_like(text: String) -> bool:
	var name := _bare_name(text)
	return not name.is_empty() and name.split(" ", false).size() <= 4 and _regex("name", "^[\\p{L}][\\p{L}'. -]{0,40}$").search(name) != null

static func _bare_name(text: String) -> String:
	return text.strip_edges().trim_suffix(".").trim_suffix("!").strip_edges()

static func _capital(word: String) -> String:
	return word.left(1).to_upper() + word.substr(1).to_lower()

## The clean text's sentences, each trimmed: a sentence ends at . ! ? or a line break.
static func sentences(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for found: RegExMatch in _regex("sentence", "[^.!?\\n]+[.!?]*[\"')]*").search_all(clean(text)):
		var sentence := found.get_string().strip_edges()
		if not sentence.is_empty() and _regex("has_word", "[\\p{L}\\p{N}]").search(sentence) != null: out.append(sentence)
	return out

## The clean text's words, lower case.
static func words(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for found: RegExMatch in _regex("word", "[\\p{L}\\p{N}]+(?:['’][\\p{L}]+)*").search_all(clean(text)):
		out.append(found.get_string().to_lower().replace("’", "'"))
	return out

## Dictated words added to a letter: "scratch that" anywhere crosses out the sentence before it
## (the words before it are written first), "new line" / "new paragraph" break the line, and a
## new sentence starts with a capital.
static func dictate(text: String, heard: String) -> String:
	var chunk := heard.strip_edges()
	var scratch := _regex("scratch", "(?i)\\bscratch that\\b[\\s.,!?;:]*")
	var found := scratch.search(chunk)
	while found != null:
		text = append(text, chunk.substr(0, found.get_start()))
		text = strike_last_sentence(text)
		chunk = chunk.substr(found.get_end())
		found = scratch.search(chunk)
	return append(text, chunk)

## Appends words: a space or nothing between, "new line" spoken as a line break, the first
## letter capitalised after a sentence end or at the start. Clipped to MAX_CHARS.
static func append(text: String, words_in: String) -> String:
	var chunk := _regex("newline", "(?i)[\\s,]*\\bnew (line|paragraph)\\b[\\s,.]*").sub(words_in.strip_edges(), "\n", true)
	var pieces := chunk.split("\n")
	for piece_index in pieces.size():
		var piece: String = pieces[piece_index].strip_edges()
		if piece_index > 0: text = text.strip_edges(false, true) + "\n"
		if piece.is_empty(): continue
		var bare := text.replace(STRIKE, "").strip_edges(false, true)
		if bare.is_empty() or bare.ends_with(".") or bare.ends_with("!") or bare.ends_with("?") or text.ends_with("\n"):
			piece = piece.left(1).to_upper() + piece.substr(1)
		if not text.is_empty() and not text.ends_with("\n") and not text.ends_with(" "): text += " "
		text += piece
	return _greeting_break(text).left(MAX_CHARS)

## A spoken greeting runs straight on ("Dear Twilight, hello there."): the greeting keeps its own
## first line, as a written one has.
static func _greeting_break(text: String) -> String:
	var lower := text.to_lower()
	for word: String in GREETINGS:
		if not lower.begins_with(word + " "): continue
		var comma := text.find(",")
		var newline := text.find("\n")
		if comma < 0 or comma > 60 or (newline >= 0 and newline < comma): return text
		var rest := text.substr(comma + 1).strip_edges(true, false)
		if rest.is_empty() or rest.begins_with("\n"): return text
		return text.substr(0, comma + 1) + "\n" + rest.left(1).to_upper() + rest.substr(1)
	return text

## A typed line that is only "scratch that" (any case or punctuation).
static func is_scratch_line(line: String) -> bool:
	return _regex("scratch_line", "(?i)^[\\s.,!?]*scratch that[\\s.,!?]*$").search(line) != null
