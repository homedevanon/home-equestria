extends RefCounted
## One boundary for model control syntax. A broken tag is never ordinary speech.
## Unclosed tags end at a newline so valid dialogue on the next line can survive.
const EMOTIONS := ["neutral", "happy", "sad", "angry", "annoyed", "fearful", "surprised", "calm", "disgusted", "whispering", "shouting"]

## A director-note line written without its <brain> block: the upper-case labels of
## story_memory.gd BRAIN_INSTRUCTION at a line start. Speech never opens a line with "NEXT:".
const NOTE_LINE := "(?m)^[ \\t]*(?:WANT(?:[ \\t]+[A-Za-z0-9_]+)?|ELSEWHERE|NEXT|DONE(?:[ \\t]+[A-Za-z0-9_]+)?)[ \\t]*:[^\\n]*(?:\\n|$)"

## These are game director notes, never spoken dialogue. A missing opener was observed in
## play: WANT/ELSEWHERE/NEXT/DONE text followed by </brain> reached the voice pipeline.
## An orphan closer discards the ambiguous prefix; an unclosed opener discards its suffix.
## Keep this independent of story storage and call it again at the final TTS boundary.
## Small local models (thread 43671981, 2026-11-03: Gemma 12B) also write the notes with no tags at
## all, or put reasoning in <think> blocks (an orphan </think> when the server opened the block
## itself), or wrap the notes in a Markdown fence: none of it is speech.
static func without_private_notes(text: String) -> String:
	text = RegEx.create_from_string(NOTE_LINE).sub(text, "", true)
	if not "<" in text: return text.strip_edges()
	var tags := RegEx.create_from_string("(?is)<\\s*(/?)\\s*(?:brain|story|think|thinking)\\b[^>]*(?:>|$)")
	var found := false
	var out := ""
	var cursor := 0
	var depth := 0
	for tag: RegExMatch in tags.search_all(text):
		found = true
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
	if found: out = RegEx.create_from_string("(?m)^[ \\t]*```[A-Za-z]*[ \\t]*(?:\\n|$)").sub(out, "", true)
	return out.strip_edges()

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
