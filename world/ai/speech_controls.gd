extends RefCounted
## One boundary for model control syntax. A broken tag is never ordinary speech.
## Unclosed tags end at a newline so valid dialogue on the next line can survive.
const EMOTIONS := ["neutral", "happy", "sad", "angry", "annoyed", "fearful", "surprised", "calm", "disgusted", "whispering", "shouting"]

## These are game director notes, never spoken dialogue. A missing opener was observed in
## play: WANT/ELSEWHERE/NEXT/DONE text followed by </brain> reached the voice pipeline.
## An orphan closer discards the ambiguous prefix; an unclosed opener discards its suffix.
## Keep this independent of story storage and call it again at the final TTS boundary.
static func without_private_notes(text: String) -> String:
	# Models also substitute [brain] for <brain>. Removing only the square tags
	# would leave their contents to be spoken as ordinary dialogue.
	if "[" in text:
		var square := RegEx.create_from_string("(?i)\\[\\s*(/?)\\s*(brain|story)\\s*\\]")
		text = square.sub(text, "<$1$2>", true)
	if not "<" in text: return _without_bare_private_notes(text)
	var tags := RegEx.create_from_string("(?is)<\\s*(/?)\\s*(?:brain|story)\\b[^>]*(?:>|$)")
	var out := ""
	var cursor := 0
	var depth := 0
	for tag: RegExMatch in tags.search_all(text):
		if tag.get_string(1).is_empty():
			if depth == 0: out += text.substr(cursor, tag.get_start() - cursor)
			if not tag.get_string().strip_edges().ends_with("/>"): depth += 1
		elif depth > 0:
			depth -= 1
		else:
			# With no opener there is no trustworthy boundary between notes and speech.
			out = ""
		cursor = tag.get_end()
	if depth == 0: out += text.substr(cursor)
	return _without_bare_private_notes(out)

## With no delimiters, require multiple reserved fields before treating lines as
## a broken director block. A lone label or a sentence mentioning WANT stays speech.
static func _without_bare_private_notes(text: String) -> String:
	var upper := text.to_upper()
	if not "WANT" in upper: return text.strip_edges()
	var field := RegEx.create_from_string("(?i)^[ \\t]*(?:[a-z_][a-z0-9_]*:[ \\t]*)?(WANT|ELSEWHERE|NEXT|DONE)(?:[ \\t]+[a-z_][a-z0-9_]*)?[ \\t]*:")
	var lines := text.split("\n")
	var fields := {}
	for line: String in lines:
		var note := field.search(line)
		if note != null: fields[note.get_string(1).to_upper()] = true
	if not fields.has("WANT") or not (fields.has("ELSEWHERE") or fields.has("NEXT")):
		return text.strip_edges()
	var speech: PackedStringArray = []
	for line: String in lines:
		if field.search(line) == null: speech.append(line)
	return "\n".join(speech).strip_edges()

static func spans(text: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var i := 0
	while i < text.length():
		if text[i] != "[": i += 1; continue
		var start := i
		var depth := 1
		var nested := false
		i += 1
		while i < text.length() and text[i] not in ["\r", "\n"]:
			if text[i] == "[": depth += 1; nested = true
			elif text[i] == "]":
				depth -= 1
				if depth == 0: i += 1; break
			i += 1
		result.append({"start": start, "end": i, "complete": depth == 0 and not nested,
			"tag": text.substr(start, i - start)})
	return result

static func presentation_tag(tag: String) -> bool:
	if tag.length() < 2 or not tag.ends_with("]"): return false
	var body := tag.substr(1, tag.length() - 2).strip_edges().to_lower()
	if body in EMOTIONS or body in ["hoofraise", "magic", "excited", "wave", "cheer", "point", "shrug", "fire", "eat"]: return true
	if body in ["hoofraise:left", "hoofraise:right", "wings", "wings:spread", "wings:flutter"]: return true
	if body.begins_with("face:"):
		return body.substr(5).strip_edges() in preload("res://world/ai/pony_dialogue_tags.gd").NAMES
	return false

static func sanitize(text: String, keep_presentation := false) -> String:
	text = without_private_notes(text)
	var out := ""
	var cursor := 0
	for span: Dictionary in spans(text):
		out += text.substr(cursor, int(span.start) - cursor)
		if keep_presentation and span.complete and presentation_tag(str(span.tag)):
			out += str(span.tag)
		cursor = int(span.end)
	out += text.substr(cursor)
	out = out.replace("]", "") if not keep_presentation else _strip_loose_closers(out)
	while "  " in out: out = out.replace("  ", " ")
	return out.strip_edges()

static func _strip_loose_closers(text: String) -> String:
	var out := ""
	var inside := false
	for character in text:
		if character == "[": inside = true
		if character != "]" or inside: out += character
		if character == "]": inside = false
	return out
