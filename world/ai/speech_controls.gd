extends RefCounted
## One boundary for model control syntax. A broken tag is never ordinary speech.
## Unclosed tags end at a newline so valid dialogue on the next line can survive.
const EMOTIONS := ["neutral", "happy", "sad", "angry", "annoyed", "fearful", "surprised", "calm", "disgusted", "whispering", "shouting"]

## A director-note line written without its <brain> block: the upper-case labels of
## story_memory.gd BRAIN_INSTRUCTION at a line start, also after a group line's speaker prefix
## ("luna: WANT: ..."; GitHub PR #13). Speech never opens a line with "NEXT:", so a lone NEXT line
## is dropped too (D-37 leaves that to the dev).
const NOTE_LINE := "(?m)^[ \\t]*(?:[A-Za-z][A-Za-z0-9_']*(?:[ \\t]+[A-Za-z][A-Za-z0-9_']*){0,2}[ \\t]*:[ \\t]*)?(?:WANT(?:[ \\t]+[A-Za-z0-9_]+)?|ELSEWHERE|NEXT|DONE(?:[ \\t]+[A-Za-z0-9_]+)?)[ \\t]*:[^\\n]*(?:\\n|$)"
## Square note wrappers ([brain]...[/brain], [story], any case and spacing; GitHub PR #13): some models
## write the notes block with the brackets of the action tags, and "[brain]note[/brain]Hello!" reached
## the voice as "noteHello!". They become angle tags first (angle_notes), so the block is never spoken
## and story_memory.gd still stores it.
const SQUARE_NOTE := "(?i)\\[\\s*(/?)\\s*(brain|story)\\s*\\]"

## These are game director notes, never spoken dialogue. A missing opener was observed in
## play: WANT/ELSEWHERE/NEXT/DONE text followed by </brain> reached the voice pipeline.
## An orphan closer discards the ambiguous prefix; an unclosed opener discards its suffix.
## Keep this independent of story storage and call it again at the final TTS boundary.
## Small local models (thread 43671981, 2026-11-03: Gemma 12B) also write the notes with no tags at
## all, or put reasoning in <think> blocks (an orphan </think> when the server opened the block
## itself), or wrap the notes in a Markdown fence: none of it is speech.
static func without_private_notes(text: String) -> String:
	text = angle_notes(text)
	# Blocks first: an orphan closer ends a note line ("WANT: plan.</brain>Hello!" keeps "Hello!").
	if "<" in text: text = _without_note_blocks(text)
	return RegEx.create_from_string(NOTE_LINE).sub(text, "", true).strip_edges()

## [brain]/[/brain] and [story]/[/story] as <brain>/</brain> and <story>/</story>; other text unchanged.
static func angle_notes(text: String) -> String:
	if not "[" in text: return text
	var out := ""
	var cursor := 0
	for tag: RegExMatch in RegEx.create_from_string(SQUARE_NOTE).search_all(text):
		out += text.substr(cursor, tag.get_start() - cursor) + "<" + tag.get_string(1) + tag.get_string(2).to_lower() + ">"
		cursor = tag.get_end()
	return out + text.substr(cursor) if cursor > 0 else text

static func _without_note_blocks(text: String) -> String:
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
	return out

## True when the line has a letter or digit of any script to say: "...", "~" or a lone "♪" is not
## speech. Any script counts, so a reply in Japanese or Chinese still reaches a voice that can say it.
static func has_words(text: String) -> bool:
	return RegEx.create_from_string("[\\p{L}\\p{N}]").search(text) != null

## The ponese voice's own word test (native pony_ponese_voice.cpp is_word_char): without such a
## letter it answers "empty ponese line".
static func has_ponese_words(text: String) -> bool:
	return RegEx.create_from_string("[A-Za-z0-9\\x{00C0}-\\x{1FFF}]").search(text) != null

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

## Stars taken off a stressed word; the rule lives with the tags (pony_dialogue_tags.gd), which
## this file already reads, so the two files do not load each other in a ring.
static func unstar(text: String) -> String:
	return preload("res://world/ai/pony_dialogue_tags.gd").unstar(text)

static func _strip_loose_closers(text: String) -> String:
	var out := ""
	var inside := false
	for character in text:
		if character == "[": inside = true
		if character != "]" or inside: out += character
		if character == "]": inside = false
	return out
