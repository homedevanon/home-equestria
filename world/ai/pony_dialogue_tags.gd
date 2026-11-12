extends RefCounted
## Facial expressions for a spoken line: one per sentence at most, and a later sentence may change it
## (dev 2026-11-03: "allow ponies to use multiple facial expressions in a single response").
## Tags are never spoken or remembered.
const NAMES := ["neutral", "happy", "delighted", "silly", "amused", "crookedsmile", "relaxed", "shy", "sad", "annoyed", "angersmug", "suspicious", "angry", "ponyrage", "fearful", "disgusted", "surprised", "confused", "ooo", "anticipation", "affectionate", "pain"]
const PROMPT := "Expression tags (optional, sparing, never spoken): a line may start with one face, [face:NAME] with NAME neutral, happy, delighted, silly, amused, crookedsmile, relaxed, shy, sad, annoyed, angersmug, suspicious, angry, ponyrage, fearful, disgusted, surprised, confused, ooo, anticipation, affectionate or pain ([face:happy] Good to see you.); a later sentence may start with a new face when her feeling changes mid-reply ([face:delighted] Hi! [face:sad] But I lost my kite.), and the face holds until changed. Then optionally a voice emotion, usually omitted: [neutral] [happy] [sad] [angry] [annoyed] [fearful] [surprised] [calm] [shouting]. Occasionally, when a real pony would move while talking, one gesture as the line starts: [hoofraise] (or [hoofraise:left]/[hoofraise:right]) lifts a curled forehoof to make a point, greet, plead or emphasise; [excited] shows excitement (a pegasus spreads her wings, a unicorn's horn sparks, an earth pony kicks up a hind hoof); unicorns and alicorns only: [magic] lights the horn a moment; pegasi and alicorns only: [wings:spread] holds the wings open a few seconds, [wings:flutter] gives a quick excited open-and-shut."
## Spike's own gestures (wave, cheer, point, shrug, fire, eat) are explained in his prompt only
## (world/ai/prompts/spike.md), so the shared prompt above costs every pony nothing extra.
const GESTURES := ["hoofraise", "magic", "wings", "excited", "wave", "cheer", "point", "shrug", "fire", "eat"]

static func parse(text: String) -> Dictionary:
	var regex := RegEx.new()
	regex.compile("(?i)\\[face\\s*:\\s*([^\\]\\r\\n]*)\\]")
	var expression := ""
	for match_value in regex.search_all(text):
		var value := match_value.get_string(1).strip_edges().to_lower()
		if expression.is_empty() and value in NAMES: expression = value
	var gestures := RegEx.new()
	gestures.compile("(?i)\\[\\s*(hoofraise|magic|wings|excited|wave|cheer|point|shrug|fire|eat)\\s*(?::\\s*(left|right|spread|flutter)\\s*)?\\]")
	var gesture := ""
	var found := gestures.search(text)
	if found != null: gesture = found.get_string(1).to_lower() + (":" + found.get_string(2).to_lower() if found.get_string(2) != "" else "")
	var speech := gestures.sub(regex.sub(text, "", true), "", true)
	return {"speech":speech.strip_edges(), "face":expression, "gesture":gesture}

## Faces per sentence of a raw tagged line (split by speech_sentences.gd `split`), in order:
## [{"key": letters of the sentence, "face": NAME}]. A sentence without its own face tag keeps the
## one before it ("" before the first).
static func sentence_faces(sentences: Array[String]) -> Array:
	var regex := RegEx.new()
	regex.compile("(?i)\\[face\\s*:\\s*([^\\]\\r\\n]*)\\]")
	var result: Array = []
	var face := ""
	for sentence: String in sentences:
		for match_value in regex.search_all(sentence):
			var value := match_value.get_string(1).strip_edges().to_lower()
			if value in NAMES:
				face = value
				break
		var key := sentence_key(sentence)
		if not key.is_empty(): result.append({"key": key, "face": face})
	return result

## A model marks a stressed word with stars ("he is a *child*, dear", "A *date*?") as well as
## stage directions ("*sighs* Well..."). The cleaners drop everything between stars, which lost
## the stressed word and left "he is a , dear" (dev 2026-11-11). This takes the stars off a
## stressed word and leaves stage directions for the cleaners: starred words that follow a word
## of the same clause, or one starred word right before "?" or "!".
static var _stressed: RegEx
static func unstar(text: String) -> String:
	if not "*" in text: return text
	if _stressed == null:
		_stressed = RegEx.create_from_string("(?<=[\\p{L}\\p{N}] )\\*{1,2}([^*\\n]{1,40}?)\\*{1,2}(?=[\\s,.!?;:\u2026\u2014-]|$)|\\*{1,2}([\\p{L}'\u2019-]{1,24})\\*{1,2}(?=[?!])")
	return _stressed.sub(text, "$1$2", true)

## A sentence reduced to lower-case letters and digits, without bracket tags or *actions*, so a raw
## sentence and its cleaned spoken copy compare equal.
static func sentence_key(text: String) -> String:
	var tags := RegEx.new()
	tags.compile("\\*[^*]*\\*|\\[[^\\]]*\\]")
	var plain := tags.sub(unstar(text), "", true).to_lower()
	var out := ""
	for c in plain:
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"): out += c
	return out

## The face for one spoken sentence of a line: the first unused entry of `faces` (from
## sentence_faces) at or after `cursor[0]` whose text matches; the cursor moves past it. No match
## keeps `fallback`.
static func face_for(faces: Array, sentence: String, cursor: Array, fallback: String) -> String:
	var key := sentence_key(sentence)
	if key.is_empty(): return fallback
	for i in range(int(cursor[0]), faces.size()):
		var entry: String = faces[i].key
		if entry == key or entry.contains(key) or key.contains(entry):
			cursor[0] = i if entry.length() > key.length() else i + 1
			return str(faces[i].face)
	return fallback
