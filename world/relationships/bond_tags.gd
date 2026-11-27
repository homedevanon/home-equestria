extends RefCounted
## Reads the tags she writes about Anon: [felt: WORD, why], [friend: STEP, why], [heart: STEP, why]
## and [us: KIND, ANSWER] (docs/RELATIONSHIP_OVERHAUL_2026_11_21.md section 4.4, the November 20
## section 4.4 rows that stand, contract docs/RELATIONSHIP_BUILD_2026_11_21.md section 3.4).
##
## The only reading here is of a tag's own argument: split on commas, each piece looked up in the
## tables of bond_rules.gd. Nothing reads her spoken words or his line, and nothing here judges: what
## she tagged is written into the feeling dictionary as she tagged it, and the Memory package decides
## nothing more from it than the design's section 12 allows.
const BOND := preload("res://world/relationships/bond_rules.gd")
## Sizes of what is kept from one reply (the same limits pony_impressions.sanitize checks).
const ENTRIES_KEPT := 2
const RAW_CHARS := 24
const FORGIVE_MAX := 9

## One tag of her reply, `name` and `value` as the decoder read them. True when it was a feeling tag,
## a standing tag naming a step, or a step tag, and it has been written into `impression`; the decoder
## then skips it. False leaves it to the decoder: every action, the old number tags, the three old step
## tags. Always false while the switch is off.
static func read(name: String, value: String, impression: Dictionary) -> bool:
	if not BOND.DYNAMIC: return false
	var tag := BOND.key(name)
	if tag.is_empty() or tag in BOND.OLD_TAGS: return false
	var parts := _parts(value)
	if tag in BOND.FELT_NAMES: return _felt(parts, impression)
	if tag in BOND.STEP_NAMES: return _us(parts, impression)
	if (tag in BOND.FRIEND_NAMES or tag in BOND.HEART_NAMES) and _stand(tag, parts, impression): return true
	# A KIND written as the tag's own name with an answer: [kiss: no], [hug: no], [date: yes].
	var kind := BOND.kind(tag)
	if kind.is_empty() or parts.is_empty(): return false
	var answer := BOND.answer(parts[0])
	if answer.is_empty(): return false
	# [kiss_player: no] and [cuddle: no] are a no; with any other answer they stay the act they name.
	if tag in BOND.NEGATIVE_ONLY and answer != "no": return false
	_add_us(impression, kind, answer, ", ".join(parts.slice(1)))
	return true

## The second look's tags-only answer as a feeling dictionary ({} when it held no tag this file reads).
## The answer is the reader model's own tag list, never her speech; it is cut at its brackets and
## each tag goes through read() exactly as her own tag would.
static func parse_reply(text: String) -> Dictionary:
	var impression := {}
	var at := 0
	while at < text.length():
		var open := text.find("[", at)
		if open < 0: break
		var close := text.find("]", open + 1)
		if close < 0: break
		at = close + 1
		var body := text.substr(open + 1, close - open - 1)
		var cut := _separator(body)
		var name := body.left(cut) if cut >= 0 else body
		var value := body.substr(cut + 1) if cut >= 0 else ""
		read(name, value.strip_edges(), impression)
	return impression

## The first ":" or "=", as the decoder separates a tag's name from its value; -1 when neither.
static func _separator(body: String) -> int:
	var colon := body.find(":")
	var equals := body.find("=")
	if colon < 0: return equals
	if equals < 0: return colon
	return mini(colon, equals)

static func _parts(value: String) -> PackedStringArray:
	var parts := PackedStringArray()
	if value.strip_edges().is_empty(): return parts
	for piece: String in value.split(","):
		parts.append(piece.strip_edges())
	return parts

## [felt: WORD], [felt: WORD, why], [felt: forgiving, N, why]. The first feeling tag of a reply wins;
## a later one is claimed and left out.
static func _felt(parts: PackedStringArray, impression: Dictionary) -> bool:
	if parts.is_empty() or parts[0].is_empty(): return false
	# [feel: rarity +1] is her feeling about another pony (story_memory.gd): a number in the first
	# piece leaves the tag to the decoder.
	for token: String in parts[0].split(" ", false):
		if token.is_valid_int(): return false
	if impression.has("felt"): return true
	# Only the whole argument is read: exactly one listed word or one near word of BOND.NEAR. Anything
	# else ("not happy", "touched and flattered", "sad") is not read: felt stays empty, felt_raw keeps
	# what she wrote, and the "felt" repair and the second look take it from there.
	impression["felt_raw"] = parts[0].left(RAW_CHARS)
	var word := BOND.word(parts[0])
	if word == BOND.OTHER: return true
	impression["felt"] = word
	var rest := parts.slice(1)
	if word == "forgiving" and not rest.is_empty() and rest[0].is_valid_int():
		impression["forgive"] = clampi(rest[0].to_int(), 0, FORGIVE_MAX)
		rest = rest.slice(1)
	var why := ", ".join(rest).strip_edges()
	if not why.is_empty(): impression["why"] = why.left(BOND.WHY_MAX)
	return true

## [friend: STEP, why] and [heart: STEP, why]. Only an argument that names a step is a standing tag:
## [friendship: +2] and [romance: 1] stay the old number tags.
static func _stand(tag: String, parts: PackedStringArray, impression: Dictionary) -> bool:
	if parts.is_empty(): return false
	var ladder := "friend" if tag in BOND.FRIEND_NAMES else "heart"
	var step := BOND.closeness_step(parts[0]) if ladder == "friend" else BOND.heart_step(parts[0])
	if step.is_empty(): return false
	var stand: Array = impression.get("stand", [])
	if stand.size() < ENTRIES_KEPT:
		stand.append({"ladder": ladder, "step": step, "why": ", ".join(parts.slice(1)).strip_edges().left(BOND.WHY_MAX)})
	impression["stand"] = stand
	return true

## [us: KIND, ANSWER] and [us: KIND, ANSWER, EXTRA]; [us: KIND] is kept with the answer "" (held, and
## her next prompt asks which it was). [us: yes, couple] is read the right way round.
static func _us(parts: PackedStringArray, impression: Dictionary) -> bool:
	if parts.is_empty(): return false
	var kind := BOND.kind(parts[0])
	var answer := BOND.answer(parts[1]) if parts.size() > 1 else ""
	if kind.is_empty() and parts.size() > 1 and not BOND.answer(parts[0]).is_empty() and not BOND.kind(parts[1]).is_empty():
		kind = BOND.kind(parts[1])
		answer = BOND.answer(parts[0])
	if kind.is_empty(): return false
	_add_us(impression, kind, answer, ", ".join(parts.slice(2)))
	return true

## At most two step entries a reply; a third is claimed and dropped.
static func _add_us(impression: Dictionary, kind: String, answer: String, extra: String) -> void:
	var steps: Array = impression.get("us", [])
	if steps.size() < ENTRIES_KEPT:
		steps.append({"kind": kind, "answer": answer, "extra": extra.strip_edges().left(RAW_CHARS)})
	impression["us"] = steps
